import CoreImage
import Foundation
import ImageIO
import PixeltjeMacDomain

public struct RawInspection: Equatable, Sendable {
  public var selectedDecoderVersion: String
  public var supportedDecoderVersions: [String]
  public var defaults: RawParameters
  public var capabilities: RawCapabilities
  public var exifOrientation: Int32
  public var nativeWidth: Int
  public var nativeHeight: Int

  public init(
    selectedDecoderVersion: String,
    supportedDecoderVersions: [String],
    defaults: RawParameters,
    capabilities: RawCapabilities,
    exifOrientation: Int32,
    nativeWidth: Int,
    nativeHeight: Int
  ) {
    self.selectedDecoderVersion = selectedDecoderVersion
    self.supportedDecoderVersions = supportedDecoderVersions
    self.defaults = defaults
    self.capabilities = capabilities
    self.exifOrientation = exifOrientation
    self.nativeWidth = nativeWidth
    self.nativeHeight = nativeHeight
  }
}

struct PreparedRaw {
  let image: CIImage
  let inspection: RawInspection
}

/// The sole construction and mutation boundary for CIRAWFilter.
final class RawCoreImage {
  private let filter: CIRAWFilter
  let inspection: RawInspection

  private init(filter: CIRAWFilter, inspection: RawInspection) {
    self.filter = filter
    self.inspection = inspection
  }

  static func create(
    input: RawInput,
    recipe: RawDevelopmentRecipe
  ) async throws -> sending RawCoreImage {
    let filter: CIRAWFilter? =
      switch input {
      case .file(let url): CIRAWFilter(imageURL: url)
      }

    guard let filter else {
      throw PixeltjeMacError(
        "Unsupported RAW file",
        "The RAW system installed with macOS cannot open \(input.displayName)."
      )
    }

    let supported = filter.supportedDecoderVersions
    let selected = try selectDecoder(requested: recipe.decoderVersion, supported: supported)
    filter.decoderVersion = selected

    if selected == .version9 || selected == .version9DNG {
      try await prepareResources(for: filter)
    }

    // Keep the Apple decode in sensor orientation. Orientation is applied once,
    // after the complete RAW image has been materialized.
    filter.orientation = .up

    let capabilities = RawCapabilities(
      luminanceNoiseReduction: filter.isLuminanceNoiseReductionSupported,
      colorNoiseReduction: filter.isColorNoiseReductionSupported,
      sharpness: filter.isSharpnessSupported,
      contrast: filter.isContrastSupported,
      detail: filter.isDetailSupported,
      moireReduction: filter.isMoireReductionSupported,
      despeckle: filter.isDespeckleSupported,
      localToneMap: filter.isLocalToneMapSupported,
      highlightRecovery: filter.isHighlightRecoverySupported,
      lensCorrection: filter.isLensCorrectionSupported
    )
    let defaults = captureParameters(from: filter)
    let nativeSize = filter.nativeSize
    return RawCoreImage(
      filter: filter,
      inspection: RawInspection(
        selectedDecoderVersion: selected.rawValue,
        supportedDecoderVersions: supported.map(\.rawValue),
        defaults: defaults,
        capabilities: capabilities,
        exifOrientation: exifOrientation(from: filter.properties),
        nativeWidth: Int(nativeSize.width.rounded()),
        nativeHeight: Int(nativeSize.height.rounded())
      )
    )
  }

  // Called synchronously on the owning render actor. Never share a mutable filter
  // between preview and full resolution: changing quality discards RAW intermediates.
  func prepare(parameters: RawParameters, quality: RenderQuality) throws -> PreparedRaw {
    Self.apply(parameters, capabilities: inspection.capabilities, to: filter)
    switch quality {
    case .full:
      if filter.isDraftModeEnabled { filter.isDraftModeEnabled = false }
      if filter.scaleFactor != 1 { filter.scaleFactor = 1 }
    case .proxy(let maximumLongEdge):
      if !filter.isDraftModeEnabled { filter.isDraftModeEnabled = true }
      // nativeSize changes after draft evaluation on macOS 27. Always use the
      // original sensor size or repeated slider edits change preview dimensions.
      let longEdge = Double(max(inspection.nativeWidth, inspection.nativeHeight))
      let scale = Float(min(max(Double(maximumLongEdge) / max(longEdge, 1), 0.01), 1))
      if filter.scaleFactor != scale { filter.scaleFactor = scale }
    }
    guard let output = filter.outputImage else {
      throw PixeltjeMacError("RAW rendering failed", "CIRAWFilter did not produce an image.")
    }
    return PreparedRaw(image: output, inspection: inspection)
  }

  private static func selectDecoder(
    requested: String?,
    supported: [CIRAWDecoderVersion]
  ) throws -> CIRAWDecoderVersion {
    if let requested {
      let version = CIRAWDecoderVersion(rawValue: requested)
      guard supported.contains(version) else {
        throw PixeltjeMacError(
          "RAW decoder unavailable",
          "This project requires Apple RAW decoder \(requested), but this file and macOS installation do not support it."
        )
      }
      return version
    }

    // Select by identifier, never by the ordering of supportedDecoderVersions.
    for preferred in [CIRAWDecoderVersion.version9, .version9DNG]
    where supported.contains(preferred) {
      return preferred
    }
    for preferred in [
      CIRAWDecoderVersion.version8, .version8DNG,
      .version7, .version7DNG, .version6, .version6DNG,
    ]
    where supported.contains(preferred) {
      return preferred
    }

    throw PixeltjeMacError(
      "RAW decoder unavailable",
      "macOS reported no usable public decoder for this RAW file."
    )
  }

  private static func prepareResources(for filter: CIRAWFilter) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      _ = filter.downloadResources(timeout: 120) { error in
        if let error {
          continuation.resume(
            throwing: PixeltjeMacError(
              "RAW resources unavailable",
              "macOS could not prepare the selected RAW decoder: \(error.localizedDescription)"
            ))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private static func captureParameters(from filter: CIRAWFilter) -> RawParameters {
    RawParameters(
      exposure: Double(filter.exposure),
      baselineExposure: Double(filter.baselineExposure),
      shadowBias: Double(filter.shadowBias),
      boostAmount: Double(filter.boostAmount),
      boostShadowAmount: Double(filter.boostShadowAmount),
      luminanceNoiseReduction: Double(filter.luminanceNoiseReductionAmount),
      colorNoiseReduction: Double(filter.colorNoiseReductionAmount),
      sharpness: Double(filter.sharpnessAmount),
      contrast: Double(filter.contrastAmount),
      detail: Double(filter.detailAmount),
      moireReduction: Double(filter.moireReductionAmount),
      despeckle: Double(filter.despeckleAmount),
      localToneMap: Double(filter.localToneMapAmount),
      extendedDynamicRange: Double(filter.extendedDynamicRangeAmount),
      neutralTemperature: Double(filter.neutralTemperature),
      neutralTint: Double(filter.neutralTint),
      highlightRecovery: filter.isHighlightRecoveryEnabled,
      gamutMapping: filter.isGamutMappingEnabled,
      lensCorrection: filter.isLensCorrectionEnabled
    )
  }

  private static func apply(
    _ parameters: RawParameters,
    capabilities: RawCapabilities,
    to filter: CIRAWFilter
  ) {
    if filter.exposure != Float(parameters.exposure) {
      filter.exposure = Float(parameters.exposure)
    }
    if filter.baselineExposure != Float(parameters.baselineExposure) {
      filter.baselineExposure = Float(parameters.baselineExposure)
    }
    if filter.shadowBias != Float(parameters.shadowBias) {
      filter.shadowBias = Float(parameters.shadowBias)
    }
    if filter.boostAmount != Float(parameters.boostAmount) {
      filter.boostAmount = Float(parameters.boostAmount)
    }
    if filter.boostShadowAmount != Float(parameters.boostShadowAmount) {
      filter.boostShadowAmount = Float(parameters.boostShadowAmount)
    }
    if filter.isGamutMappingEnabled != parameters.gamutMapping {
      filter.isGamutMappingEnabled = parameters.gamutMapping
    }
    if filter.extendedDynamicRangeAmount != Float(parameters.extendedDynamicRange) {
      filter.extendedDynamicRangeAmount = Float(parameters.extendedDynamicRange)
    }
    if filter.neutralTemperature != Float(parameters.neutralTemperature) {
      filter.neutralTemperature = Float(parameters.neutralTemperature)
    }
    if filter.neutralTint != Float(parameters.neutralTint) {
      filter.neutralTint = Float(parameters.neutralTint)
    }

    if capabilities.highlightRecovery {
      if filter.isHighlightRecoveryEnabled != parameters.highlightRecovery {
        filter.isHighlightRecoveryEnabled = parameters.highlightRecovery
      }
    }
    if capabilities.lensCorrection {
      if filter.isLensCorrectionEnabled != parameters.lensCorrection {
        filter.isLensCorrectionEnabled = parameters.lensCorrection
      }
    }
    if capabilities.luminanceNoiseReduction {
      if filter.luminanceNoiseReductionAmount != Float(parameters.luminanceNoiseReduction) {
        filter.luminanceNoiseReductionAmount = Float(parameters.luminanceNoiseReduction)
      }
    }
    if capabilities.colorNoiseReduction {
      if filter.colorNoiseReductionAmount != Float(parameters.colorNoiseReduction) {
        filter.colorNoiseReductionAmount = Float(parameters.colorNoiseReduction)
      }
    }
    if capabilities.sharpness {
      if filter.sharpnessAmount != Float(parameters.sharpness) {
        filter.sharpnessAmount = Float(parameters.sharpness)
      }
    }
    if capabilities.contrast {
      if filter.contrastAmount != Float(parameters.contrast) {
        filter.contrastAmount = Float(parameters.contrast)
      }
    }
    if capabilities.detail {
      if filter.detailAmount != Float(parameters.detail) {
        filter.detailAmount = Float(parameters.detail)
      }
    }
    if capabilities.moireReduction {
      if filter.moireReductionAmount != Float(parameters.moireReduction) {
        filter.moireReductionAmount = Float(parameters.moireReduction)
      }
    }
    if capabilities.despeckle {
      if filter.despeckleAmount != Float(parameters.despeckle) {
        filter.despeckleAmount = Float(parameters.despeckle)
      }
    }
    if capabilities.localToneMap {
      if filter.localToneMapAmount != Float(parameters.localToneMap) {
        filter.localToneMapAmount = Float(parameters.localToneMap)
      }
    }
  }

  private static func exifOrientation(from properties: [AnyHashable: Any]) -> Int32 {
    let value = properties[kCGImagePropertyOrientation] as? NSNumber
    let orientation = value?.int32Value ?? 1
    return (1...8).contains(orientation) ? orientation : 1
  }
}
