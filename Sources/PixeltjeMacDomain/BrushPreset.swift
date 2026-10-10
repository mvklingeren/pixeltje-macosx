import Foundation

/// The user-facing group a brush appears in. Its identity is stored separately
/// from localized labels so artwork never depends on panel wording.
public enum BrushCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case pencils
  case ink
  case markers
  case painting
  case charcoalAndPastel

  public var label: String {
    switch self {
    case .pencils: "Pencils"
    case .ink: "Ink"
    case .markers: "Markers"
    case .painting: "Painting"
    case .charcoalAndPastel: "Charcoal & Pastel"
    }
  }
}

public enum BrushPresetID: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
  case hbPencil
  case sixBPencil
  case fineliner
  case inkBrush
  case fountainPen
  case roundMarker
  case chiselHighlighter
  case hardRound
  case softAirbrush
  case flatBrush
  case dryBrush
  case watercolorWash
  case charcoal
  case softPastel

  public var id: String { rawValue }
}

public enum BrushTipShape: String, Codable, Equatable, Sendable {
  case round
  case ellipse
  case roundedRectangle
}

public enum BrushOrientationMode: String, Codable, Equatable, Sendable {
  case fixed
  case strokeDirection
  case barrelRotation
  case tilt
}

public enum BrushGrain: String, Codable, Equatable, Sendable {
  case none
  case paper
  case coarse
  case bristles
  case wash
}

public enum BrushDeposition: String, Codable, Equatable, Sendable {
  case accumulating
  /// Coverage may build from separate strokes, but a stroke does not darken
  /// itself where its stamps overlap.
  case restrained
}

/// All appearance-affecting data copied into a version-2 stroke. Catalog
/// changes therefore never alter a stroke already saved in a project.
public struct BrushDefinition: Codable, Equatable, Sendable {
  public var presetID: BrushPresetID
  public var revision: Int
  public var tipShape: BrushTipShape
  public var aspectRatio: Double
  public var orientation: BrushOrientationMode
  public var grain: BrushGrain
  public var grainAmount: Double
  public var deposition: BrushDeposition
  public var pressureAffectsSize: Bool
  public var pressureAffectsOpacity: Bool
  public var tiltShading: Bool

  public init(
    presetID: BrushPresetID,
    revision: Int = 1,
    tipShape: BrushTipShape = .round,
    aspectRatio: Double = 1,
    orientation: BrushOrientationMode = .fixed,
    grain: BrushGrain = .none,
    grainAmount: Double = 0,
    deposition: BrushDeposition = .accumulating,
    pressureAffectsSize: Bool = true,
    pressureAffectsOpacity: Bool = true,
    tiltShading: Bool = false
  ) {
    self.presetID = presetID
    self.revision = max(revision, 1)
    self.tipShape = tipShape
    self.aspectRatio = aspectRatio.isFinite ? min(max(aspectRatio, 0.08), 1) : 1
    self.orientation = orientation
    self.grain = grain
    self.grainAmount = grainAmount.isFinite ? min(max(grainAmount, 0), 1) : 0
    self.deposition = deposition
    self.pressureAffectsSize = pressureAffectsSize
    self.pressureAffectsOpacity = pressureAffectsOpacity
    self.tiltShading = tiltShading
  }
}

/// A built-in preset. The catalog is deliberately procedural and has no
/// external resource dependency.
public struct BrushPreset: Equatable, Sendable, Identifiable {
  public let id: BrushPresetID
  public let category: BrushCategory
  public let name: String
  /// A fixed catalog identity color used only for the brush-library sample.
  /// It never changes the color that the brush paints into a document.
  public let previewColor: LinearRGBAColor
  public let definition: BrushDefinition
  public let settings: BrushSettings

  public init(
    _ id: BrushPresetID,
    category: BrushCategory,
    name: String,
    previewColor: LinearRGBAColor,
    definition: BrushDefinition,
    settings: BrushSettings
  ) {
    self.id = id
    self.category = category
    self.name = name
    self.previewColor = previewColor
    self.definition = definition
    self.settings = settings
  }
}

public enum BrushCatalog {
  /// What a new document, the eraser, and any unrecognized identity fall back
  /// to. Named rather than found by position, so reordering the library cannot
  /// quietly change the definition every new stroke captures.
  public static let hardRound = make(
    .hardRound, .painting, "Hard Round", .round,
    settings: BrushSettings(size: 40, hardness: 1, opacity: 1, flow: 1, spacing: 0.12, pressureResponse: 0.75))

  public static let presets: [BrushPreset] = [
    make(.hbPencil, .pencils, "HB Pencil", .round, grain: .paper, grainAmount: 0.28,
         settings: BrushSettings(size: 12, hardness: 0.72, opacity: 0.74, flow: 0.42, spacing: 0.08, pressureResponse: 0.22)),
    make(.sixBPencil, .pencils, "6B Pencil", .ellipse, orientation: .tilt,
         grain: .paper, grainAmount: 0.46, tilt: true, settings: BrushSettings(size: 19, hardness: 0.46, opacity: 0.88, flow: 0.58, spacing: 0.07, pressureResponse: 0.34)),
    make(.fineliner, .ink, "Fineliner", .round, sizePressure: false,
         opacityPressure: false, settings: BrushSettings(size: 5, hardness: 1, opacity: 1, flow: 1, spacing: 0.06, pressureResponse: 0)),
    make(.inkBrush, .ink, "Ink Brush", .round,
         settings: BrushSettings(size: 28, hardness: 0.94, opacity: 1, flow: 0.9, spacing: 0.06, pressureResponse: 0.92)),
    make(.fountainPen, .ink, "Fountain Pen", .roundedRectangle, aspectRatio: 0.22,
         orientation: .barrelRotation, sizePressure: false,
         settings: BrushSettings(size: 22, hardness: 1, opacity: 1, flow: 0.92, spacing: 0.05, pressureResponse: 0.35)),
    make(.roundMarker, .markers, "Round Marker", .round, deposition: .restrained,
         sizePressure: false, settings: BrushSettings(size: 46, hardness: 0.83, opacity: 0.78, flow: 0.85, spacing: 0.09, pressureResponse: 0.15)),
    make(.chiselHighlighter, .markers, "Chisel Highlighter", .roundedRectangle, aspectRatio: 0.28,
         orientation: .barrelRotation, deposition: .restrained, sizePressure: false,
         settings: BrushSettings(size: 55, hardness: 0.75, opacity: 0.35, flow: 1, spacing: 0.08, pressureResponse: 0)),
    hardRound,
    make(.softAirbrush, .painting, "Soft Airbrush", .round,
         settings: BrushSettings(size: 90, hardness: 0, opacity: 0.58, flow: 0.12, spacing: 0.08, pressureResponse: 0.35)),
    make(.flatBrush, .painting, "Flat Brush", .roundedRectangle, aspectRatio: 0.35,
         orientation: .strokeDirection, grain: .bristles, grainAmount: 0.2,
         settings: BrushSettings(size: 54, hardness: 0.72, opacity: 0.92, flow: 0.62, spacing: 0.08, pressureResponse: 0.52)),
    make(.dryBrush, .painting, "Dry Brush", .roundedRectangle, aspectRatio: 0.4,
         orientation: .strokeDirection, grain: .bristles, grainAmount: 0.64,
         settings: BrushSettings(size: 45, hardness: 0.67, opacity: 0.9, flow: 0.5, spacing: 0.08, pressureResponse: 0.6)),
    make(.watercolorWash, .painting, "Watercolor Wash", .round, grain: .wash, grainAmount: 0.36,
         deposition: .restrained, settings: BrushSettings(size: 96, hardness: 0.12, opacity: 0.46, flow: 0.36, spacing: 0.1, pressureResponse: 0.28)),
    make(.charcoal, .charcoalAndPastel, "Charcoal", .ellipse, orientation: .tilt,
         grain: .coarse, grainAmount: 0.62, tilt: true, settings: BrushSettings(size: 34, hardness: 0.48, opacity: 0.78, flow: 0.55, spacing: 0.06, pressureResponse: 0.42)),
    make(.softPastel, .charcoalAndPastel, "Soft Pastel", .ellipse, orientation: .tilt,
         grain: .coarse, grainAmount: 0.35, tilt: true, settings: BrushSettings(size: 42, hardness: 0.42, opacity: 0.86, flow: 0.64, spacing: 0.07, pressureResponse: 0.37)),
  ]

  public static func preset(_ id: BrushPresetID) -> BrushPreset {
    presets.first(where: { $0.id == id }) ?? hardRound
  }

  public static func presets(in category: BrushCategory) -> [BrushPreset] {
    presets.filter { $0.category == category }
  }

  private static func make(
    _ id: BrushPresetID,
    _ category: BrushCategory,
    _ name: String,
    _ tip: BrushTipShape,
    aspectRatio: Double = 1,
    orientation: BrushOrientationMode = .fixed,
    grain: BrushGrain = .none,
    grainAmount: Double = 0,
    deposition: BrushDeposition = .accumulating,
    sizePressure: Bool = true,
    opacityPressure: Bool = true,
    tilt: Bool = false,
    settings: BrushSettings
  ) -> BrushPreset {
    BrushPreset(id, category: category, name: name, previewColor: previewColor(for: id),
      definition: BrushDefinition(presetID: id, tipShape: tip, aspectRatio: aspectRatio,
        orientation: orientation, grain: grain, grainAmount: grainAmount,
        deposition: deposition, pressureAffectsSize: sizePressure,
        pressureAffectsOpacity: opacityPressure, tiltShading: tilt), settings: settings)
  }

  /// The semantic preview palette, written as familiar gamma-encoded Display
  /// P3 hex values and converted to the renderer's linear working space.
  private static func previewColor(for id: BrushPresetID) -> LinearRGBAColor {
    let hex: UInt32 = switch id {
    case .hbPencil: 0x667085
    case .sixBPencil: 0x343A40
    case .fineliner: 0x16697A
    case .inkBrush: 0x29377C
    case .fountainPen: 0x4169C1
    case .roundMarker: 0xE45756
    case .chiselHighlighter: 0xF2C94C
    case .hardRound: 0x1683F3
    case .softAirbrush: 0x9B6DE3
    case .flatBrush: 0xEB7440
    case .dryBrush: 0xA9633B
    case .watercolorWash: 0x20B8B2
    case .charcoal: 0x4B4641
    case .softPastel: 0xD978A5
    }
    return LinearRGBAColor(
      red: linearComponent(UInt8((hex >> 16) & 0xFF)),
      green: linearComponent(UInt8((hex >> 8) & 0xFF)),
      blue: linearComponent(UInt8(hex & 0xFF))
    )
  }

  /// Display P3 uses the sRGB transfer curve, so conversion to linear light is
  /// component-wise even though the primaries differ from sRGB.
  private static func linearComponent(_ component: UInt8) -> Double {
    let encoded = Double(component) / 255
    if encoded <= 0.04045 { return encoded / 12.92 }
    return pow((encoded + 0.055) / 1.055, 2.4)
  }
}
