import Foundation

/// How a layer's pixels combine with everything composited beneath it.
///
/// Most modes map to a Core Image blend filter. Difference Key instead derives
/// a soft matte from the color difference with the visible layers beneath it.
public enum LayerBlendMode: String, Codable, CaseIterable, Sendable {
  case normal
  case differenceKey
  case multiply
  case screen
  case overlay
  case darken
  case lighten
  case colorDodge
  case colorBurn
  case softLight
  case hardLight
  case difference
  case exclusion
  case hue
  case saturation
  case color
  case luminosity

  public var label: String {
    switch self {
    case .normal: "Normal"
    case .differenceKey: "Difference Key"
    case .multiply: "Multiply"
    case .screen: "Screen"
    case .overlay: "Overlay"
    case .darken: "Darken"
    case .lighten: "Lighten"
    case .colorDodge: "Color Dodge"
    case .colorBurn: "Color Burn"
    case .softLight: "Soft Light"
    case .hardLight: "Hard Light"
    case .difference: "Difference"
    case .exclusion: "Exclusion"
    case .hue: "Hue"
    case .saturation: "Saturation"
    case .color: "Color"
    case .luminosity: "Luminosity"
    }
  }
}

public enum DifferenceKeyReference: String, Codable, CaseIterable, Sendable {
  case currentBackdrop
  case generationInput

  public var label: String {
    switch self {
    case .currentBackdrop: "Current Backdrop"
    case .generationInput: "Generation Input"
    }
  }
}

/// The way one layer meets the visible layers beneath it.
///
/// Opacity and fill are multipliers in `0...1`. Opacity scales everything the layer
/// contributes; fill scales only the layer's own pixels and, once layer styles
/// exist, leaves a drop shadow or stroke at full strength. There are no layer
/// styles yet, so today the two multiply to the same result. They are still
/// recorded separately in the recipe so a project written now keeps the
/// distinction when styles arrive, instead of needing a migration that guesses
/// which slider the user meant.
public struct LayerCompositing: Codable, Equatable, Sendable {
  public var blendMode: LayerBlendMode
  public var opacity: Double
  public var fill: Double
  /// Percentage of average channel difference needed by Difference Key.
  public var differenceCutoff: Double
  /// Width of Difference Key's soft transition, in percentage points. Zero is a hard cutoff.
  public var differenceSoftness: Double
  /// Gaussian neighborhood radius in canvas pixels, before the cutoff.
  public var differenceRadius: Double
  /// Strength of the high-confidence pixel signal that preserves small edits.
  public var differenceFineDetail: Double
  /// How much structural change contributes alongside perceptual color change.
  public var differenceStructure: Double
  /// Suppresses broad, low-frequency model color drift during detection.
  public var differenceDrift: Double
  /// Signed growth of the detected region, independent of edge feathering.
  public var differenceGrow: Double
  public var differenceFeather: Double
  public var differenceReference: DifferenceKeyReference
  /// Shared editor masks copied from a selection for explicit corrections.
  public var differenceRevealMask: MaskRecipe?
  public var differenceProtectMask: MaskRecipe?

  public init(
    blendMode: LayerBlendMode = .normal,
    opacity: Double = 1,
    fill: Double = 1,
    differenceCutoff: Double = 8,
    differenceSoftness: Double = 4,
    differenceRadius: Double = 3,
    differenceFineDetail: Double = 65,
    differenceStructure: Double = 25,
    differenceDrift: Double = 0,
    differenceGrow: Double = 1.5,
    differenceFeather: Double = 1.5,
    differenceReference: DifferenceKeyReference = .currentBackdrop,
    differenceRevealMask: MaskRecipe? = nil,
    differenceProtectMask: MaskRecipe? = nil
  ) {
    self.blendMode = blendMode
    self.opacity = Self.clamped(opacity)
    self.fill = Self.clamped(fill)
    self.differenceCutoff = Self.clampedPercentage(differenceCutoff, fallback: 8)
    self.differenceSoftness = Self.clampedPercentage(differenceSoftness, fallback: 4)
    self.differenceRadius = Self.clampedRadius(differenceRadius)
    self.differenceFineDetail = Self.clampedPercentage(differenceFineDetail, fallback: 65)
    self.differenceStructure = Self.clampedPercentage(differenceStructure, fallback: 25)
    self.differenceDrift = Self.clampedPercentage(differenceDrift, fallback: 0)
    self.differenceGrow = Self.clampedSignedRadius(differenceGrow)
    self.differenceFeather = Self.clampedRadius(differenceFeather)
    self.differenceReference = differenceReference
    self.differenceRevealMask = differenceRevealMask
    self.differenceProtectMask = differenceProtectMask
  }

  public static let normal = LayerCompositing()

  /// Whether compositing this layer is plain source-over at full strength.
  public var isPassThrough: Bool {
    blendMode == .normal && opacity == 1 && fill == 1
  }

  public static func clamped(_ value: Double) -> Double {
    guard value.isFinite else { return 1 }
    return min(max(value, 0), 1)
  }

  public static func clampedPercentage(_ value: Double, fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(max(value, 0), 100)
  }

  public static func clampedRadius(_ value: Double) -> Double {
    guard value.isFinite else { return 3 }
    return min(max(value, 0), 32)
  }

  public static func clampedSignedRadius(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, -32), 32)
  }

  private enum CodingKeys: String, CodingKey {
    case blendMode, opacity, fill, differenceCutoff, differenceSoftness, differenceRadius
    case differenceFineDetail
    case differenceStructure, differenceDrift, differenceGrow, differenceFeather
    case differenceReference, differenceRevealMask, differenceProtectMask
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      blendMode: try values.decodeIfPresent(LayerBlendMode.self, forKey: .blendMode) ?? .normal,
      opacity: try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
      fill: try values.decodeIfPresent(Double.self, forKey: .fill) ?? 1,
      differenceCutoff: try values.decodeIfPresent(Double.self, forKey: .differenceCutoff) ?? 8,
      differenceSoftness: try values.decodeIfPresent(Double.self, forKey: .differenceSoftness) ?? 4,
      differenceRadius: try values.decodeIfPresent(Double.self, forKey: .differenceRadius) ?? 3,
      differenceFineDetail: try values.decodeIfPresent(Double.self,
        forKey: .differenceFineDetail) ?? 65,
      differenceStructure: try values.decodeIfPresent(Double.self, forKey: .differenceStructure) ?? 25,
      differenceDrift: try values.decodeIfPresent(Double.self, forKey: .differenceDrift) ?? 0,
      differenceGrow: try values.decodeIfPresent(Double.self, forKey: .differenceGrow) ?? 1.5,
      differenceFeather: try values.decodeIfPresent(Double.self, forKey: .differenceFeather) ?? 1.5,
      differenceReference: try values.decodeIfPresent(DifferenceKeyReference.self,
        forKey: .differenceReference) ?? .currentBackdrop,
      differenceRevealMask: try values.decodeIfPresent(MaskRecipe.self,
        forKey: .differenceRevealMask),
      differenceProtectMask: try values.decodeIfPresent(MaskRecipe.self,
        forKey: .differenceProtectMask))
  }
}

public enum TextLayerAlignment: String, Codable, CaseIterable, Sendable {
  case leading
  case center
  case trailing

  public var label: String {
    switch self {
    case .leading: "Left"
    case .center: "Center"
    case .trailing: "Right"
    }
  }
}

/// A block of text set inside a rectangle on the canvas.
///
/// The frame is in canvas pixels, like an image layer's; text wraps inside it
/// and flows from its top edge. Font size is in canvas pixels too, so the text
/// scales with a proxy render exactly as placed pixels do. The color is written
/// in Display P3 components, the way vector artwork colors are, and enters the
/// linear working space through a color-managed conversion when rendered.
public struct TextLayer: Codable, Equatable, Sendable {
  public var text: String
  public var fontName: String
  public var fontSize: Double
  public var color: VectorColor
  public var alignment: TextLayerAlignment
  public var frame: LayerFrame

  public static let defaultFontName = "Helvetica Neue"

  public init(
    text: String,
    fontName: String = TextLayer.defaultFontName,
    fontSize: Double,
    color: VectorColor = .white,
    alignment: TextLayerAlignment = .center,
    frame: LayerFrame
  ) {
    self.text = text
    self.fontName = fontName
    self.fontSize = max(fontSize, 1)
    self.color = color
    self.alignment = alignment
    self.frame = frame
  }

  /// A text block sized and centered for a canvas.
  ///
  /// Roughly a headline: a tenth of the canvas height tall, spanning most of
  /// its width. A canvas whose size is not known yet gets a fixed box.
  public static func placing(_ text: String, in canvas: CanvasRecipe) -> TextLayer {
    guard canvas.isResolved else {
      return TextLayer(
        text: text, fontSize: 48, frame: LayerFrame(x: 0, y: 0, width: 400, height: 120))
    }
    let width = Double(canvas.width)
    let height = Double(canvas.height)
    let fontSize = max((height / 12).rounded(), 8)
    let boxWidth = (width * 0.8).rounded()
    let boxHeight = (fontSize * 2.4).rounded()
    return TextLayer(
      text: text,
      fontSize: fontSize,
      frame: LayerFrame(
        x: ((width - boxWidth) / 2).rounded(),
        y: ((height - boxHeight) / 2).rounded(),
        width: boxWidth,
        height: boxHeight
      )
    )
  }

  /// A default text block moved so its center follows a click on the canvas.
  ///
  /// `position` is normalized to the canvas, like the points produced by the
  /// canvas tools. Keeping the whole frame inside the canvas makes clicks near
  /// an edge useful without creating text that starts off-canvas.
  public static func placing(
    _ text: String,
    in canvas: CanvasRecipe,
    centeredAt position: VectorPoint
  ) -> TextLayer {
    var placed = placing(text, in: canvas)
    guard canvas.isResolved else { return placed }

    let canvasWidth = Double(canvas.width)
    let canvasHeight = Double(canvas.height)
    let centerX = min(max(position.x, 0), 1) * canvasWidth
    let centerY = min(max(position.y, 0), 1) * canvasHeight
    placed.frame.x = min(
      max((centerX - placed.frame.width / 2).rounded(), 0),
      max(canvasWidth - placed.frame.width, 0)
    )
    placed.frame.y = min(
      max((centerY - placed.frame.height / 2).rounded(), 0),
      max(canvasHeight - placed.frame.height, 0)
    )
    return placed
  }
}

/// An ordered set of layers composited as one.
///
/// Children are stored the way the stack is: topmost first. A group is
/// composited onto a transparent canvas of its own and the result is blended
/// over the layers beneath it with the group's blend mode, opacity and fill, so
/// an adjustment layer inside a group reaches its siblings below and nothing
/// outside.
public struct GroupLayer: Codable, Equatable, Sendable {
  public var children: [ProjectLayer]

  public init(children: [ProjectLayer] = []) {
    self.children = children
  }
}

public enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
  case exposure
  case colorControls
  case curves
  case levels
  case hueSaturation
  case blackAndWhite
  case colorLookup
  case gradientMap
  case invert

  public var label: String {
    switch self {
    case .exposure: "Exposure"
    case .colorControls: "Brightness & Contrast"
    case .curves: "Curves"
    case .levels: "Levels"
    case .hueSaturation: "Hue & Saturation"
    case .blackAndWhite: "Black & White"
    case .colorLookup: "Color Lookup"
    case .gradientMap: "Gradient Map"
    case .invert: "Invert"
    }
  }

  public var defaultRecipe: AdjustmentRecipe {
    switch self {
    case .exposure: .exposure(ev: 0)
    case .colorControls: .colorControls(brightness: 0, contrast: 1, saturation: 1)
    case .curves: .curves(.neutral)
    case .levels: .levels(.neutral)
    case .hueSaturation: .hueSaturation(.neutral)
    case .blackAndWhite: .blackAndWhite(.neutral)
    case .colorLookup: .colorLookup(.neutral)
    case .gradientMap: .gradientMap(.neutral)
    case .invert: .invert
    }
  }
}

/// What an adjustment layer does to the pixels beneath it.
///
/// Every case is a serializable, deterministic operation in the downstream
/// Extended Linear Display P3 graph. New adjustment defaults are neutral, so
/// inserting one does not change pixels until its controls move.
public enum AdjustmentRecipe: Codable, Equatable, Sendable {
  case exposure(ev: Double)
  case colorControls(brightness: Double, contrast: Double, saturation: Double)
  case curves(ToneCurveRecipe)
  case levels(LevelsAdjustment)
  case hueSaturation(HueSaturationAdjustment)
  case blackAndWhite(BlackAndWhiteAdjustment)
  case colorLookup(ColorLookupAdjustment)
  case gradientMap(GradientMapAdjustment)
  case invert

  public var kind: AdjustmentKind {
    switch self {
    case .exposure: .exposure
    case .colorControls: .colorControls
    case .curves: .curves
    case .levels: .levels
    case .hueSaturation: .hueSaturation
    case .blackAndWhite: .blackAndWhite
    case .colorLookup: .colorLookup
    case .gradientMap: .gradientMap
    case .invert: .invert
    }
  }

  public var label: String { kind.label }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(AdjustmentKind.self, forKey: .kind) {
    case .exposure:
      self = .exposure(ev: try container.decodeIfPresent(Double.self, forKey: .ev) ?? 0)
    case .colorControls:
      self = .colorControls(
        brightness: try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0,
        contrast: try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
        saturation: try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
      )
    case .curves:
      self = .curves(
        try container.decodeIfPresent(ToneCurveRecipe.self, forKey: .toneCurve) ?? .neutral)
    case .levels:
      self = .levels(
        try container.decodeIfPresent(LevelsAdjustment.self, forKey: .levels) ?? .neutral)
    case .hueSaturation:
      self = .hueSaturation(
        try container.decodeIfPresent(HueSaturationAdjustment.self, forKey: .hueSaturation)
          ?? .neutral)
    case .blackAndWhite:
      self = .blackAndWhite(
        try container.decodeIfPresent(BlackAndWhiteAdjustment.self, forKey: .blackAndWhite)
          ?? .neutral)
    case .colorLookup:
      self = .colorLookup(
        try container.decodeIfPresent(ColorLookupAdjustment.self, forKey: .colorLookup)
          ?? .neutral)
    case .gradientMap:
      self = .gradientMap(
        try container.decodeIfPresent(GradientMapAdjustment.self, forKey: .gradientMap)
          ?? .neutral)
    case .invert:
      self = .invert
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .exposure(let ev):
      try container.encode(ev, forKey: .ev)
    case .colorControls(let brightness, let contrast, let saturation):
      try container.encode(brightness, forKey: .brightness)
      try container.encode(contrast, forKey: .contrast)
      try container.encode(saturation, forKey: .saturation)
    case .curves(let curve):
      try container.encode(curve, forKey: .toneCurve)
    case .levels(let levels):
      try container.encode(levels, forKey: .levels)
    case .hueSaturation(let adjustment):
      try container.encode(adjustment, forKey: .hueSaturation)
    case .blackAndWhite(let adjustment):
      try container.encode(adjustment, forKey: .blackAndWhite)
    case .colorLookup(let adjustment):
      try container.encode(adjustment, forKey: .colorLookup)
    case .gradientMap(let adjustment):
      try container.encode(adjustment, forKey: .gradientMap)
    case .invert:
      break
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case ev
    case brightness
    case contrast
    case saturation
    case toneCurve
    case levels
    case hueSaturation
    case blackAndWhite
    case colorLookup
    case gradientMap
  }
}
