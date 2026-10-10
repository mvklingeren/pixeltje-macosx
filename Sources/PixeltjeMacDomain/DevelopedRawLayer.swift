import Foundation

/// One linked camera RAW source and the Apple development recipe applied to it.
///
/// A RAW layer owns all decoder-specific state. This keeps two RAW files on one
/// canvas independent: selecting one layer in the Develop panel cannot change
/// the decoder, white balance, or lens correction of another.
public struct DevelopedRawLayer: Codable, Equatable, Sendable {
  /// The linked RAW source. It is optional only to decode pre-schema-13
  /// projects; newly created RAW layers always provide one.
  public var source: SourceReference?
  public var rawDevelopment: RawDevelopmentRecipe
  public var upright: UprightRecipe
  /// `nil` marks the document's original RAW background, whose developed
  /// extent establishes the canvas. A non-nil frame makes this a placed RAW
  /// layer, just like a placed TIFF or PNG.
  public var frame: LayerFrame?
  /// `true` only between creation of an opt-in placed RAW and its first
  /// `CIRAWFilter` inspection. The renderer uses the decoded extent to show an
  /// aspect-fitted first frame, then records a normal placement frame without
  /// asking ImageIO or another decoder to author RAW geometry.
  ///
  /// Optional preserves decoding of earlier schema-13 projects; `nil` means
  /// `false`.
  public var needsInitialPlacement: Bool?

  public init(
    source: SourceReference? = nil,
    rawDevelopment: RawDevelopmentRecipe = RawDevelopmentRecipe(),
    upright: UprightRecipe = UprightRecipe(),
    frame: LayerFrame? = nil,
    needsInitialPlacement: Bool = false
  ) {
    self.source = source
    self.rawDevelopment = rawDevelopment
    self.upright = upright.clamped
    self.frame = frame
    self.needsInitialPlacement = needsInitialPlacement ? true : nil
  }

  /// Whether this RAW has a per-layer placement frame. The document's true
  /// background RAW is identified by `ProjectLayerID.rawBackground`; older
  /// duplicated layers can also lack a frame and must not be treated as the
  /// document background merely for that reason.
  public var isPlaced: Bool { frame != nil }
}
