import Foundation

/// A prompt-derived hit map for one rendered view. It describes intended
/// placement; no generated pixels are inspected to construct or use it.
public struct PipelineScenePlan: Codable, Equatable, Sendable {
  private struct DraftRegion: Decodable {
    var id: String?
    var label: String?
    var box: [Double]?
    var nextView: String?
  }

  private enum DraftRegions: Decodable {
    case array([DraftRegion])
    case object([String: DraftRegion])

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let array = try? container.decode([DraftRegion].self) {
        self = .array(array)
      } else {
        self = .object(try container.decode([String: DraftRegion].self))
      }
    }
  }

  private struct DraftPlan: Decodable {
    var imagePrompt: String
    var defaultNextView: String?
    var regions: DraftRegions
  }

  public struct Region: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// Normalized [left, top, right, bottom] in the image for this view.
    public var box: [Double]
    public var nextView: String

    public init(id: String, label: String, box: [Double], nextView: String) {
      self.id = id
      self.label = label
      self.box = box
      self.nextView = nextView
    }

    fileprivate var area: Double {
      (box[2] - box[0]) * (box[3] - box[1])
    }

    fileprivate func contains(x: Double, y: Double) -> Bool {
      x >= box[0] && x <= box[2] && y >= box[1] && y <= box[3]
    }
  }

  public var imagePrompt: String
  public var defaultNextView: String
  public var regions: [Region]

  public init(imagePrompt: String, defaultNextView: String, regions: [Region]) {
    self.imagePrompt = imagePrompt
    self.defaultNextView = defaultNextView
    self.regions = regions
  }

  public static func decode(_ source: String) throws -> Self {
    var json = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix("```") {
      guard let firstLineEnd = json.firstIndex(of: "\n"), json.hasSuffix("```") else {
        throw PipelineEngineError.invalidInvocation(
          "The scene writer must return a JSON object, optionally in one fenced block.")
      }
      json = String(json[json.index(after: firstLineEnd)..<json.index(json.endIndex, offsetBy: -3)])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = json.data(using: .utf8) else {
      throw PipelineEngineError.invalidInvocation("The scene plan is not UTF-8 text.")
    }
    let draft: DraftPlan
    do {
      draft = try JSONDecoder().decode(DraftPlan.self, from: data)
    } catch {
      throw PipelineEngineError.invalidInvocation(
        "The scene writer returned invalid scene-plan JSON: \(error.localizedDescription)")
    }
    let entries: [(String, DraftRegion)]
    switch draft.regions {
    case .array(let array):
      entries = array.enumerated().map { index, region in
        let id = region.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id.flatMap { $0.isEmpty ? nil : $0 } ?? "region-\(index + 1)", region)
      }
    case .object(let object):
      entries = object.keys.sorted().compactMap { key in object[key].map { (key, $0) } }
    }
    var usedIDs: Set<String> = []
    var rejected: [String] = []
    var regions: [Region] = []
    for (key, region) in entries {
      guard let box = region.box.flatMap(Self.normalizedBox) else {
        rejected.append(key)
        continue
      }
      let label = region.label?.trimmingCharacters(in: .whitespacesAndNewlines)
      var resolvedID = key
      var suffix = 2
      while usedIDs.contains(resolvedID) {
        resolvedID = "\(key)-\(suffix)"
        suffix += 1
      }
      usedIDs.insert(resolvedID)
      let resolvedLabel = label.flatMap { $0.isEmpty ? nil : $0 } ?? resolvedID
      let onward = region.nextView?.trimmingCharacters(in: .whitespacesAndNewlines)
      regions.append(Region(
        id: resolvedID,
        label: resolvedLabel,
        box: box,
        nextView: onward.flatMap { $0.isEmpty ? nil : $0 }
          ?? "Move closer to the \(resolvedLabel) and reveal a coherent, explorable next view."))
      if regions.count == 16 { break }
    }
    guard !regions.isEmpty else {
      let names = rejected.prefix(5).joined(separator: ", ")
      throw PipelineEngineError.invalidInvocation(
        "The scene writer returned no usable region boxes\(names.isEmpty ? "." : " (rejected: \(names)).")")
    }
    let trimmedDefault = draft.defaultNextView?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let plan = Self(
      imagePrompt: draft.imagePrompt,
      defaultNextView: trimmedDefault.flatMap { $0.isEmpty ? nil : $0 }
        ?? "Continue forward through the open scene and reveal a new explorable detail.",
      regions: regions)
    try plan.validate()
    return plan
  }

  private static func normalizedBox(_ box: [Double]) -> [Double]? {
    guard box.count == 4, box.allSatisfy(\.isFinite) else { return nil }
    let x0 = min(max(box[0], 0), 1)
    let y0 = min(max(box[1], 0), 1)
    let x1 = min(max(box[2], 0), 1)
    let y1 = min(max(box[3], 0), 1)
    let left = min(x0, x1)
    let top = min(y0, y1)
    let right = max(x0, x1)
    let bottom = max(y0, y1)
    guard right > left, bottom > top else { return nil }
    return [left, top, right, bottom]
  }

  public func encodedJSON() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard let result = String(data: data, encoding: .utf8) else {
      throw PipelineEngineError.invalidInvocation("The scene plan could not be encoded.")
    }
    return result
  }

  public func region(atX x: Double, y: Double) -> Region? {
    guard x.isFinite, y.isFinite else { return nil }
    return regions.filter { $0.contains(x: x, y: y) }
      .min { lhs, rhs in
        lhs.area == rhs.area ? lhs.id < rhs.id : lhs.area < rhs.area
      }
  }

  public func nextWriterPrompt(x: Double, y: Double) throws -> String {
    guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
      throw PipelineEngineError.invalidInvocation("Trackpad coordinates must be between 0 and 1.")
    }
    let selected = region(atX: x, y: y)
    let focus = selected?.label ?? "the open scene"
    let move: String
    if selected != nil {
      move = "Create the NEXT image after the viewer physically walks into the \(focus) selected at x=\(x),y=\(y) in the PREVIOUS image. "
        + "The new camera stands close to the \(focus). Show the \(focus) huge in the center and foreground, with visible materials, structural details, and an inviting new object or passage beyond it. "
        + "The former wide view is behind the camera; do not repeat that opening composition. This is a new shot at the \(focus), not a caption or future plan."
    } else {
      move = "Create the NEXT image after the viewer physically walks forward through the open scene. "
        + "The new camera stands at a different, closer destination. Show a new subject large and central with an inviting detail beyond it. "
        + "The former wide view is behind the camera; do not repeat that opening composition. \(defaultNextView)"
    }
    let inferredDetail = "Move closer to the \(focus) and reveal a coherent, explorable next view."
    let authoredDetail = selected.flatMap { $0.nextView == inferredDetail ? nil : $0.nextView }
    let detail = authoredDetail.map { " Destination detail: \($0)" } ?? ""
    return """
      \(move)\(detail)
      Previous image prompt for visual continuity only (do not copy its framing): \(imagePrompt)
      Return the current NEW imagePrompt and a NEW clickable regions map. imagePrompt must describe visible contents of the NEW image only, without navigation instructions or field names. Put new boxes around objects where they appear in this new close view.
      """
  }

  private func validate() throws {
    func nonempty(_ value: String) -> Bool {
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 4_096
    }
    guard nonempty(imagePrompt), nonempty(defaultNextView),
      !regions.isEmpty, regions.count <= 16
    else {
      throw PipelineEngineError.invalidInvocation(
        "The scene plan needs an imagePrompt, defaultNextView, and 1–16 regions.")
    }
    for region in regions {
      guard nonempty(region.id), nonempty(region.label), nonempty(region.nextView),
        region.box.count == 4,
        region.box.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        region.box[0] < region.box[2], region.box[1] < region.box[3]
      else {
        throw PipelineEngineError.invalidInvocation(
          "Scene region \(region.id) has an invalid label, nextView, or normalized box.")
      }
    }
  }
}
