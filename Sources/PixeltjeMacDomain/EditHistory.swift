import Foundation

/// Identifies one recorded history step.
///
/// Steps are addressed by identity rather than by position so that trimming an
/// overlong history, or truncating the redo branch, cannot silently redirect a
/// pending undo to a different state.
public struct HistoryStepID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String = UUID().uuidString) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Identifies one pinned snapshot.
public struct HistorySnapshotID: Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String = UUID().uuidString) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// One named point in the edit history, holding the complete recipe that
/// returning to it restores.
///
/// A step stores the state *after* its edit, so the first step is the state the
/// document opened with and every later step is one named user edit.
public struct HistoryStep: Identifiable, Equatable, Codable, Sendable {
  public var id: HistoryStepID
  public var name: String
  public var date: Date
  public var recipe: ProjectRecipe

  public init(
    id: HistoryStepID = HistoryStepID(),
    name: String,
    date: Date = Date(),
    recipe: ProjectRecipe
  ) {
    self.id = id
    self.name = name
    self.date = date
    self.recipe = recipe
  }
}

/// A named state pinned out of the linear history.
///
/// Snapshots survive undo, redo and truncation: they are how a state stays
/// reachable after the branch that produced it has been replaced.
public struct HistorySnapshot: Identifiable, Equatable, Codable, Sendable {
  public var id: HistorySnapshotID
  public var name: String
  public var date: Date
  public var recipe: ProjectRecipe

  public init(
    id: HistorySnapshotID = HistorySnapshotID(),
    name: String,
    date: Date = Date(),
    recipe: ProjectRecipe
  ) {
    self.id = id
    self.name = name
    self.date = date
    self.recipe = recipe
  }
}

/// The ordered edit history of one document.
///
/// This is plain value state: recipes, names and dates. It holds no GPU, Core
/// Image or AppKit objects, so it can be inspected in tests, encoded, and read
/// from a SwiftUI view without touching the render path. Undo registration and
/// rendering stay with the document that drives it.
public struct EditHistory: Equatable, Codable, Sendable {
  /// How many steps are retained before the oldest edits are dropped.
  ///
  /// The opening state is never dropped, so returning to how the document was
  /// opened stays available however long the session runs.
  public static let defaultStepLimit = 200

  public private(set) var steps: [HistoryStep]
  public private(set) var currentIndex: Int
  public private(set) var snapshots: [HistorySnapshot]
  public var stepLimit: Int

  public init(
    initial recipe: ProjectRecipe,
    name: String = "Open",
    date: Date = Date(),
    stepLimit: Int = EditHistory.defaultStepLimit
  ) {
    self.steps = [HistoryStep(name: name, date: date, recipe: recipe)]
    self.currentIndex = 0
    self.snapshots = []
    self.stepLimit = max(2, stepLimit)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSteps = try container.decode([HistoryStep].self, forKey: .steps)
    steps =
      decodedSteps.isEmpty
      ? [HistoryStep(name: "Open", recipe: ProjectRecipe())]
      : decodedSteps
    let decodedIndex = try container.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
    currentIndex = min(max(decodedIndex, 0), steps.count - 1)
    snapshots = try container.decodeIfPresent([HistorySnapshot].self, forKey: .snapshots) ?? []
    stepLimit =
      max(2, try container.decodeIfPresent(Int.self, forKey: .stepLimit) ?? Self.defaultStepLimit)
  }

  // MARK: - Reading

  public var currentStep: HistoryStep { steps[currentIndex] }
  public var currentStepID: HistoryStepID { steps[currentIndex].id }
  public var currentRecipe: ProjectRecipe { steps[currentIndex].recipe }
  public var canUndo: Bool { currentIndex > 0 }
  public var canRedo: Bool { currentIndex < steps.count - 1 }

  public func index(of id: HistoryStepID) -> Int? {
    steps.firstIndex { $0.id == id }
  }

  public func contains(_ id: HistoryStepID) -> Bool {
    index(of: id) != nil
  }

  /// Whether a step sits ahead of the current position, meaning the next edit
  /// discards it.
  public func isAhead(_ id: HistoryStepID) -> Bool {
    guard let index = index(of: id) else { return false }
    return index > currentIndex
  }

  public func snapshot(_ id: HistorySnapshotID) -> HistorySnapshot? {
    snapshots.first { $0.id == id }
  }

  // MARK: - Recording

  /// Starts a fresh history at `recipe`, discarding steps and snapshots.
  ///
  /// Opening a file, importing a RAW, and reverting a document all begin a new
  /// editing session rather than continuing the previous one.
  public mutating func reset(
    to recipe: ProjectRecipe,
    name: String = "Open",
    date: Date = Date()
  ) {
    steps = [HistoryStep(name: name, date: date, recipe: recipe)]
    currentIndex = 0
    snapshots = []
  }

  /// Keeps the current step in step with a recipe change that is not a user
  /// edit, such as decoder metadata merged in after a render.
  ///
  /// Returning to this step later must restore what the document actually had,
  /// not the state before the metadata arrived.
  public mutating func updateCurrent(_ recipe: ProjectRecipe) {
    steps[currentIndex].recipe = recipe
  }

  /// Records one named edit and makes it current.
  ///
  /// Anything ahead of the current position is discarded first: editing after
  /// undoing replaces the abandoned branch rather than growing a tree.
  @discardableResult
  public mutating func record(
    _ recipe: ProjectRecipe,
    name: String,
    date: Date = Date()
  ) -> HistoryStepID {
    if currentIndex < steps.count - 1 {
      steps.removeSubrange((currentIndex + 1)...)
    }
    let step = HistoryStep(name: name, date: date, recipe: recipe)
    steps.append(step)
    currentIndex = steps.count - 1
    trim()
    return step.id
  }

  // MARK: - Moving

  /// Moves to an existing step and returns the recipe to restore, or `nil` when
  /// the step is unknown or already current.
  @discardableResult
  public mutating func move(to id: HistoryStepID) -> ProjectRecipe? {
    guard let index = index(of: id), index != currentIndex else { return nil }
    currentIndex = index
    return steps[index].recipe
  }

  @discardableResult
  public mutating func undo() -> ProjectRecipe? {
    guard canUndo else { return nil }
    currentIndex -= 1
    return steps[currentIndex].recipe
  }

  @discardableResult
  public mutating func redo() -> ProjectRecipe? {
    guard canRedo else { return nil }
    currentIndex += 1
    return steps[currentIndex].recipe
  }

  // MARK: - Snapshots

  @discardableResult
  public mutating func addSnapshot(
    name: String,
    recipe: ProjectRecipe,
    date: Date = Date()
  ) -> HistorySnapshotID {
    let snapshot = HistorySnapshot(name: name, date: date, recipe: recipe)
    snapshots.append(snapshot)
    return snapshot.id
  }

  public mutating func removeSnapshot(_ id: HistorySnapshotID) {
    snapshots.removeAll { $0.id == id }
  }

  public mutating func renameSnapshot(_ id: HistorySnapshotID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
    snapshots[index].name = trimmed
  }

  /// A name for the next snapshot that does not collide with an existing one.
  public func suggestedSnapshotName() -> String {
    var number = snapshots.count + 1
    let existing = Set(snapshots.map(\.name))
    while existing.contains("Snapshot \(number)") { number += 1 }
    return "Snapshot \(number)"
  }

  // MARK: - Trimming

  private mutating func trim() {
    guard steps.count > stepLimit else { return }
    // The opening state is the one step worth keeping forever; the oldest edits
    // after it are what age out.
    let excess = steps.count - stepLimit
    steps.removeSubrange(1..<(1 + excess))
    currentIndex = max(0, currentIndex - excess)
  }

  private enum CodingKeys: String, CodingKey {
    case steps
    case currentIndex
    case snapshots
    case stepLimit
  }
}
