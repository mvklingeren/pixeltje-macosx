import Foundation

/// The identity of pixels authored inside a project package.
///
/// Unlike `SourceReference`, this never points outside the document. The value
/// is the SHA-256 digest of the uncompressed pixels, which makes duplicate
/// rasterizations share one package asset without weakening source validation.
public struct RasterAssetID: Codable, Hashable, Sendable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// The recipe-side description of one losslessly stored project raster.
///
/// Version 1 stores eight bytes per pixel. Ordinary rasters are premultiplied
/// RGBA16F in Extended Linear Display P3; generated inpaint analysis maps use
/// interleaved RG32F with no color space. The payload itself is LZFSE-compressed
/// by the document layer, and the format fields select its interpretation.
public struct RasterAssetReference: Codable, Hashable, Sendable {
  public static let currentFormatVersion = 1
  public static let inpaintAnalysisPixelFormat = "rg32FloatInpaintAnalysis"

  public var id: RasterAssetID
  public var formatVersion: Int
  public var width: Int
  public var height: Int
  public var uncompressedByteCount: Int
  public var pixelFormat: String
  public var colorSpace: String

  public init(
    id: RasterAssetID,
    formatVersion: Int = currentFormatVersion,
    width: Int,
    height: Int,
    uncompressedByteCount: Int,
    pixelFormat: String = "rgba16FloatPremultiplied",
    colorSpace: String = "extendedLinearDisplayP3"
  ) {
    self.id = id
    self.formatVersion = formatVersion
    self.width = max(width, 0)
    self.height = max(height, 0)
    self.uncompressedByteCount = max(uncompressedByteCount, 0)
    self.pixelFormat = pixelFormat
    self.colorSpace = colorSpace
  }
}

/// A ComfyUI inpaint result whose frozen inputs permit local, repeatable
/// threshold changes after the job has completed and the project is reopened.
/// The analysis asset stores interleaved Float32 perceptual difference and
/// feathered selection coverage; it is never interpreted as image color.
public struct GeneratedInpaintLayerRecipe: Codable, Equatable, Sendable {
  public var source: RasterAssetReference
  public var generated: RasterAssetReference
  public var analysis: RasterAssetReference
  public var frame: LayerFrame
  public var generation: ComfyUIGenerationRecipe
  /// Local compositing control; generation inputs and server parameters remain frozen.
  public var changeThreshold: Double

  public init(
    source: RasterAssetReference,
    generated: RasterAssetReference,
    analysis: RasterAssetReference,
    frame: LayerFrame,
    generation: ComfyUIGenerationRecipe,
    changeThreshold: Double = 0
  ) {
    self.source = source
    self.generated = generated
    self.analysis = analysis
    self.frame = frame
    self.generation = generation
    self.changeThreshold = min(max(changeThreshold, 0), 100)
  }

  public var assetReferences: [RasterAssetReference] {
    [source, generated, analysis]
  }

  public var naturalSizeDescription: String {
    "\(source.width) × \(source.height) px"
  }
}

/// Pixels produced by an explicit Rasterize or Merge command.
///
/// The asset is internal to the project while `frame` remains ordinary canvas
/// geometry. A later canvas resize or transform therefore treats these pixels
/// exactly like any other placed raster rather than silently re-rasterizing the
/// vector or layers that produced them.
public struct RasterLayerRecipe: Codable, Equatable, Sendable {
  public var asset: RasterAssetReference
  public var frame: LayerFrame
  /// Present only when the pixels were produced by a generation recipe.
  public var generation: InpaintingRecipe?
  /// Present when an external ComfyUI workflow produced the pixels.
  public var comfyUIGeneration: ComfyUIGenerationRecipe?
  /// Exact canvas pixels captured for image-conditioned generation, at the
  /// output's raster dimensions. Used only when Difference Key requests a
  /// stable generation-input comparison.
  public var differenceSource: RasterAssetReference?

  public init(
    asset: RasterAssetReference,
    frame: LayerFrame,
    generation: InpaintingRecipe? = nil,
    comfyUIGeneration: ComfyUIGenerationRecipe? = nil,
    differenceSource: RasterAssetReference? = nil
  ) {
    self.asset = asset
    self.frame = frame
    self.generation = generation
    self.comfyUIGeneration = comfyUIGeneration
    self.differenceSource = differenceSource
  }

  public var naturalSizeDescription: String {
    "\(asset.width) × \(asset.height) px"
  }
}

/// A validated, ordered replacement range for Merge Layers.
public struct LayerMergePlan: Equatable, Sendable {
  public var layerIDs: [ProjectLayerID]
  public var parentID: ProjectLayerID?

  public init(layerIDs: [ProjectLayerID], parentID: ProjectLayerID?) {
    self.layerIDs = layerIDs
    self.parentID = parentID
  }
}
