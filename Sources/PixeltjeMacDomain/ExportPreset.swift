import Foundation

/// The encoded formats an export can produce.
///
/// This lives in the domain module because a preset is serializable state: the
/// format is part of the recipe for an export, not a rendering detail.
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
  case tiff
  case png
  case jpeg
  case heif

  public static func from(pathExtension: String) -> ExportFormat? {
    switch pathExtension.lowercased() {
    case "tif", "tiff": .tiff
    case "png": .png
    case "jpg", "jpeg": .jpeg
    case "heic", "heif": .heif
    default: nil
    }
  }

  public var displayName: String {
    switch self {
    case .tiff: "TIFF"
    case .png: "PNG"
    case .jpeg: "JPEG"
    case .heif: "HEIF"
    }
  }

  public var fileExtension: String {
    switch self {
    case .tiff: "tiff"
    case .png: "png"
    case .jpeg: "jpg"
    case .heif: "heic"
    }
  }

  /// Whether the encoder takes a lossy quality value.
  public var usesQuality: Bool {
    switch self {
    case .jpeg, .heif: true
    case .tiff, .png: false
    }
  }

  /// Whether the encoder can be asked for more than eight bits per component.
  public var usesBitDepth: Bool {
    switch self {
    case .tiff, .png: true
    case .jpeg, .heif: false
    }
  }
}

public enum ExportBitDepth: Int, Codable, CaseIterable, Sendable {
  case eight = 8
  case sixteen = 16

  public var displayName: String { "\(rawValue)-bit" }
}

public enum ExportResizeMode: String, Codable, CaseIterable, Sendable {
  case none
  case longEdge
  case shortEdge
  case exactDimensions
  case percentage

  public var displayName: String {
    switch self {
    case .none: "Original Size"
    case .longEdge: "Long Edge"
    case .shortEdge: "Short Edge"
    case .exactDimensions: "Exact Dimensions"
    case .percentage: "Percentage"
    }
  }
}

/// How the exported image is scaled.
///
/// One struct carries every mode's number so a preset round-trips through JSON
/// without a discriminated union, and so switching modes in the popup does not
/// discard what the other modes were set to.
public struct ExportResize: Codable, Equatable, Sendable {
  public var mode: ExportResizeMode
  public var longEdge: Int
  public var shortEdge: Int
  public var width: Int
  public var height: Int
  public var percentage: Double
  /// Whether a target larger than the source is allowed to enlarge it.
  public var allowsUpscaling: Bool

  public init(
    mode: ExportResizeMode = .none,
    longEdge: Int = 2048,
    shortEdge: Int = 1080,
    width: Int = 1920,
    height: Int = 1080,
    percentage: Double = 50,
    allowsUpscaling: Bool = false
  ) {
    self.mode = mode
    self.longEdge = longEdge
    self.shortEdge = shortEdge
    self.width = width
    self.height = height
    self.percentage = percentage
    self.allowsUpscaling = allowsUpscaling
  }

  public static let original = ExportResize()

  /// The pixel size this resize asks for, or `nil` when the source size stands.
  ///
  /// Every mode except `exactDimensions` keeps the source aspect ratio; exact
  /// dimensions fits inside the requested box rather than distorting the image,
  /// because an export must never silently stretch what the canvas showed.
  public func targetSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int)? {
    guard sourceWidth > 0, sourceHeight > 0 else { return nil }
    let sourceW = Double(sourceWidth)
    let sourceH = Double(sourceHeight)
    let scale: Double
    switch mode {
    case .none:
      return nil
    case .longEdge:
      guard longEdge > 0 else { return nil }
      scale = Double(longEdge) / max(sourceW, sourceH)
    case .shortEdge:
      guard shortEdge > 0 else { return nil }
      scale = Double(shortEdge) / min(sourceW, sourceH)
    case .exactDimensions:
      guard width > 0, height > 0 else { return nil }
      scale = min(Double(width) / sourceW, Double(height) / sourceH)
    case .percentage:
      guard percentage > 0 else { return nil }
      scale = percentage / 100
    }
    guard scale > 0, scale.isFinite else { return nil }
    if scale > 1, !allowsUpscaling { return nil }
    let targetWidth = max(1, Int((sourceW * scale).rounded()))
    let targetHeight = max(1, Int((sourceH * scale).rounded()))
    guard targetWidth != sourceWidth || targetHeight != sourceHeight else { return nil }
    return (targetWidth, targetHeight)
  }

  /// A short line describing the resize, for the popup and the queue row.
  public var summary: String {
    switch mode {
    case .none: "Original size"
    case .longEdge: "Long edge \(longEdge) px"
    case .shortEdge: "Short edge \(shortEdge) px"
    case .exactDimensions: "Fit \(width) × \(height) px"
    case .percentage: "\(Int(percentage.rounded()))%"
    }
  }
}

/// Output sharpening intent, named after the medium the file is destined for.
///
/// The amounts are deliberately conservative: this is a last step over an image
/// the user already sharpened in Detail, not a second creative control.
public enum ExportSharpeningMode: String, Codable, CaseIterable, Sendable {
  case off
  case screen
  case matte
  case glossy

  public var displayName: String {
    switch self {
    case .off: "Off"
    case .screen: "Screen"
    case .matte: "Matte Paper"
    case .glossy: "Glossy Paper"
    }
  }

  /// The unsharp-mask radius, in output pixels.
  public var radius: Double {
    switch self {
    case .off: 0
    case .screen: 0.8
    case .matte: 1.6
    case .glossy: 1.1
    }
  }

  /// The unsharp-mask intensity at amount 1.
  public var intensity: Double {
    switch self {
    case .off: 0
    case .screen: 0.55
    case .matte: 1.0
    case .glossy: 0.75
    }
  }
}

public struct ExportSharpening: Codable, Equatable, Sendable {
  public var mode: ExportSharpeningMode
  /// 0…1, scaling the mode's intensity. 0.5 is the neutral "standard" amount.
  public var amount: Double

  public init(mode: ExportSharpeningMode = .off, amount: Double = 0.5) {
    self.mode = mode
    self.amount = amount
  }

  public static let off = ExportSharpening()

  public var isEnabled: Bool { mode != .off && effectiveIntensity > 0 }

  public var radius: Double { mode.radius }

  public var effectiveIntensity: Double {
    max(0, min(1, amount)) * mode.intensity
  }

  public var summary: String {
    guard isEnabled else { return "No output sharpening" }
    return "\(mode.displayName) sharpening"
  }
}

/// Where the watermark sits inside the exported image.
public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
  case topLeft
  case topCenter
  case topRight
  case centerLeft
  case center
  case centerRight
  case bottomLeft
  case bottomCenter
  case bottomRight

  public var displayName: String {
    switch self {
    case .topLeft: "Top Left"
    case .topCenter: "Top Center"
    case .topRight: "Top Right"
    case .centerLeft: "Center Left"
    case .center: "Center"
    case .centerRight: "Center Right"
    case .bottomLeft: "Bottom Left"
    case .bottomCenter: "Bottom Center"
    case .bottomRight: "Bottom Right"
    }
  }

  /// 0 at the left/bottom edge, 1 at the right/top edge.
  public var anchor: (x: Double, y: Double) {
    switch self {
    case .topLeft: (0, 1)
    case .topCenter: (0.5, 1)
    case .topRight: (1, 1)
    case .centerLeft: (0, 0.5)
    case .center: (0.5, 0.5)
    case .centerRight: (1, 0.5)
    case .bottomLeft: (0, 0)
    case .bottomCenter: (0.5, 0)
    case .bottomRight: (1, 0)
    }
  }
}

/// A text watermark.
///
/// Text only, for now. An image watermark needs a linked-asset story of its own
/// — a preset is shared across documents, so it cannot carry pixels any more
/// than a project can — and inventing one here would be a format to migrate
/// later.
public struct ExportWatermark: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var text: String
  public var position: WatermarkPosition
  /// 0…1.
  public var opacity: Double
  /// Cap height as a percentage of the exported image's long edge.
  public var sizePercent: Double
  /// Distance from the edges, as a percentage of the long edge.
  public var insetPercent: Double

  public init(
    isEnabled: Bool = false,
    text: String = "",
    position: WatermarkPosition = .bottomRight,
    opacity: Double = 0.6,
    sizePercent: Double = 3.5,
    insetPercent: Double = 2.5
  ) {
    self.isEnabled = isEnabled
    self.text = text
    self.position = position
    self.opacity = opacity
    self.sizePercent = sizePercent
    self.insetPercent = insetPercent
  }

  public static let none = ExportWatermark()

  public var isDrawable: Bool {
    isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && opacity > 0
      && sizePercent > 0
  }

  public var summary: String {
    isDrawable ? "Watermark “\(text)” \(position.displayName.lowercased())" : "No watermark"
  }
}

/// One token a naming template understands.
public struct ExportNameToken: Identifiable, Sendable, Hashable {
  public let token: String
  public let explanation: String

  public var id: String { token }

  public init(token: String, explanation: String) {
    self.token = token
    self.explanation = explanation
  }
}

/// How an exported file is named.
///
/// The template is expanded against the original file name, a sequence number
/// and the export date. The extension is never part of the template: it follows
/// from the format, so changing the format cannot leave a misnamed file.
public struct ExportNaming: Codable, Equatable, Sendable {
  public var template: String
  public var sequencePadding: Int

  public init(template: String = "{name}", sequencePadding: Int = 3) {
    self.template = template
    self.sequencePadding = sequencePadding
  }

  public static let original = ExportNaming()

  public static let tokens: [ExportNameToken] = [
    ExportNameToken(token: "{name}", explanation: "The original file name, without extension"),
    ExportNameToken(token: "{sequence}", explanation: "An export sequence number"),
    ExportNameToken(token: "{date}", explanation: "The export date, as 2026-09-05"),
    ExportNameToken(token: "{time}", explanation: "The export time, as 14-30-05"),
    ExportNameToken(token: "{preset}", explanation: "The preset's name"),
  ]

  /// Expands the template, without an extension.
  public func expanded(
    originalName: String,
    sequence: Int,
    presetName: String,
    date: Date,
    calendar: Calendar = Calendar(identifier: .gregorian),
    timeZone: TimeZone = .current
  ) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let padded = two(parts.month) + "-" + two(parts.day)
    let day = String(format: "%04d", parts.year ?? 0) + "-" + padded
    let time = two(parts.hour) + "-" + two(parts.minute) + "-" + two(parts.second)
    let base = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
    var expanded = template.isEmpty ? "{name}" : template
    expanded = expanded.replacingOccurrences(of: "{name}", with: base)
    expanded = expanded.replacingOccurrences(
      of: "{sequence}",
      with: String(format: "%0\(max(1, sequencePadding))d", sequence)
    )
    expanded = expanded.replacingOccurrences(of: "{date}", with: day)
    expanded = expanded.replacingOccurrences(of: "{time}", with: time)
    expanded = expanded.replacingOccurrences(of: "{preset}", with: presetName)
    return Self.sanitized(expanded, fallback: base)
  }

  /// Expands the template and appends the format's extension.
  public func filename(
    originalName: String,
    sequence: Int,
    presetName: String,
    format: ExportFormat,
    date: Date = Date()
  ) -> String {
    let base = expanded(
      originalName: originalName,
      sequence: sequence,
      presetName: presetName,
      date: date
    )
    return base + "." + format.fileExtension
  }

  /// Strips what a file name may not contain, and never returns an empty name.
  public static func sanitized(_ name: String, fallback: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
    let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned.hasPrefix(".") {
      let cleanedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
      return cleanedFallback.isEmpty ? "Export" : cleanedFallback
    }
    return cleaned
  }

  private func two(_ value: Int?) -> String {
    String(format: "%02d", value ?? 0)
  }
}

/// Everything one export does, as serializable state.
///
/// A preset is a recipe for an export, so it is Codable, value-typed and free
/// of framework objects; the render engine reads it and never stores it.
public struct ExportPreset: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var format: ExportFormat
  /// 0…1, used by JPEG and HEIF.
  public var quality: Double
  /// Used by TIFF and PNG.
  public var bitDepth: ExportBitDepth
  public var colorSpace: ExportColorSpace
  public var resize: ExportResize
  public var sharpening: ExportSharpening
  public var watermark: ExportWatermark
  public var naming: ExportNaming
  /// Whether the export should embed how the image was generated.
  ///
  /// The generation features are deferred, so there is nothing to record yet.
  /// The switch exists — an export written today should say whether the user
  /// wanted it — and the export writes nothing for it rather than inventing a
  /// metadata format that a real implementation would have to migrate.
  public var embedsGenerationMetadata: Bool
  /// Built-in presets are shipped, cannot be edited in place, and are the same
  /// on every machine.
  public var isBuiltIn: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    format: ExportFormat = .tiff,
    quality: Double = 0.9,
    bitDepth: ExportBitDepth = .sixteen,
    colorSpace: ExportColorSpace = .displayP3,
    resize: ExportResize = .original,
    sharpening: ExportSharpening = .off,
    watermark: ExportWatermark = .none,
    naming: ExportNaming = .original,
    embedsGenerationMetadata: Bool = false,
    isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.format = format
    self.quality = quality
    self.bitDepth = bitDepth
    self.colorSpace = colorSpace
    self.resize = resize
    self.sharpening = sharpening
    self.watermark = watermark
    self.naming = naming
    self.embedsGenerationMetadata = embedsGenerationMetadata
    self.isBuiltIn = isBuiltIn
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Export"
    format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .tiff
    quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9
    bitDepth = try container.decodeIfPresent(ExportBitDepth.self, forKey: .bitDepth) ?? .sixteen
    colorSpace =
      try container.decodeIfPresent(ExportColorSpace.self, forKey: .colorSpace) ?? .displayP3
    resize = try container.decodeIfPresent(ExportResize.self, forKey: .resize) ?? .original
    sharpening = try container.decodeIfPresent(ExportSharpening.self, forKey: .sharpening) ?? .off
    watermark = try container.decodeIfPresent(ExportWatermark.self, forKey: .watermark) ?? .none
    naming = try container.decodeIfPresent(ExportNaming.self, forKey: .naming) ?? .original
    embedsGenerationMetadata =
      try container.decodeIfPresent(Bool.self, forKey: .embedsGenerationMetadata) ?? false
    isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
  }

  /// The effective quality, clamped to what an encoder accepts.
  public var clampedQuality: Double { max(0.05, min(1, quality)) }

  /// A one-line description for the popup and the queue.
  public var summary: String {
    var parts = [format.displayName]
    if format.usesBitDepth { parts.append(bitDepth.displayName) }
    if format.usesQuality { parts.append("q \(Int((clampedQuality * 100).rounded()))") }
    parts.append(resize.summary)
    if sharpening.isEnabled { parts.append(sharpening.mode.displayName) }
    if watermark.isDrawable { parts.append("watermark") }
    return parts.joined(separator: " • ")
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, format, quality, bitDepth, colorSpace, resize, sharpening, watermark, naming
    case embedsGenerationMetadata, isBuiltIn
  }
}

extension ExportPreset {
  private static func fixedID(_ string: String) -> UUID {
    UUID(uuidString: string) ?? UUID()
  }

  /// The presets every install starts with.
  ///
  /// Their identifiers are fixed so that "last used preset" survives a restart
  /// and so a user preset can never collide with one of them.
  public static let builtIns: [ExportPreset] = [
    ExportPreset(
      id: fixedID("6D4E1E64-0000-4000-A000-000000000001"),
      name: "Full Quality TIFF",
      format: .tiff,
      bitDepth: .sixteen,
      colorSpace: .displayP3,
      isBuiltIn: true
    ),
    ExportPreset(
      id: fixedID("6D4E1E64-0000-4000-A000-000000000002"),
      name: "Full Size JPEG",
      format: .jpeg,
      quality: 0.92,
      colorSpace: .displayP3,
      isBuiltIn: true
    ),
    ExportPreset(
      id: fixedID("6D4E1E64-0000-4000-A000-000000000003"),
      name: "Web JPEG 2048 px",
      format: .jpeg,
      quality: 0.82,
      colorSpace: .sRGB,
      resize: ExportResize(mode: .longEdge, longEdge: 2048),
      sharpening: ExportSharpening(mode: .screen, amount: 0.5),
      naming: ExportNaming(template: "{name}-2048"),
      isBuiltIn: true
    ),
    ExportPreset(
      id: fixedID("6D4E1E64-0000-4000-A000-000000000004"),
      name: "Email JPEG 1200 px",
      format: .jpeg,
      quality: 0.72,
      colorSpace: .sRGB,
      resize: ExportResize(mode: .longEdge, longEdge: 1200),
      sharpening: ExportSharpening(mode: .screen, amount: 0.4),
      naming: ExportNaming(template: "{name}-email"),
      isBuiltIn: true
    ),
    ExportPreset(
      id: fixedID("6D4E1E64-0000-4000-A000-000000000005"),
      name: "PNG 8-bit",
      format: .png,
      bitDepth: .eight,
      colorSpace: .displayP3,
      isBuiltIn: true
    ),
    ExportPreset(
      id: fixedID("6D4E1E64-0000-4000-A000-000000000006"),
      name: "HEIF Full Size",
      format: .heif,
      quality: 0.85,
      colorSpace: .displayP3,
      isBuiltIn: true
    ),
  ]

  public static var defaultPreset: ExportPreset { builtIns[0] }

  /// A copy of this preset that the user owns.
  public func duplicated(named name: String) -> ExportPreset {
    var copy = self
    copy.id = UUID()
    copy.name = name
    copy.isBuiltIn = false
    return copy
  }
}

/// The presets available to every document.
///
/// Presets are not part of a project: the same "Web JPEG" is wanted in every
/// document, so the library lives in app settings and the project records only
/// what it renders.
public struct ExportPresetLibrary: Codable, Equatable, Sendable {
  public var userPresets: [ExportPreset]

  public init(userPresets: [ExportPreset] = []) {
    self.userPresets = userPresets
  }

  public var all: [ExportPreset] { ExportPreset.builtIns + userPresets }

  public func preset(id: UUID) -> ExportPreset? {
    all.first { $0.id == id }
  }

  /// Adds a user preset, or replaces the one with the same identifier.
  ///
  /// A built-in is never overwritten: saving over one stores a user copy that
  /// shadows nothing, so the shipped preset stays available.
  public mutating func save(_ preset: ExportPreset) {
    var stored = preset
    stored.isBuiltIn = false
    if ExportPreset.builtIns.contains(where: { $0.id == stored.id }) {
      stored.id = UUID()
    }
    if let index = userPresets.firstIndex(where: { $0.id == stored.id }) {
      userPresets[index] = stored
    } else {
      userPresets.append(stored)
    }
  }

  public mutating func remove(id: UUID) {
    userPresets.removeAll { $0.id == id }
  }
}
