import CryptoKit
import Foundation
import PixeltjeMacDomain

/// Lossless storage boundary for pixels authored inside a project package.
/// The domain records the interpretation; this helper owns compression and
/// identity verification without involving Core Image or Metal.
enum RasterAssetPayload {
  static func encode(
    _ pixels: Data,
    width: Int,
    height: Int,
    pixelFormat: String = "rgba16FloatPremultiplied",
    colorSpace: String = "extendedLinearDisplayP3"
  ) throws -> (reference: RasterAssetReference, compressedPixels: Data) {
    let expectedByteCount = try byteCount(width: width, height: height)
    guard pixels.count == expectedByteCount else {
      throw PixeltjeMacError(
        "Rasterization failed",
        "The rendered pixel payload did not match its dimensions."
      )
    }
    let id = RasterAssetID(rawValue: sha256(pixels))
    return (
      RasterAssetReference(
        id: id,
        width: width,
        height: height,
        uncompressedByteCount: expectedByteCount,
        pixelFormat: pixelFormat,
        colorSpace: colorSpace
      ),
      try (pixels as NSData).compressed(using: .lzfse) as Data
    )
  }

  static func decode(
    _ compressedPixels: Data,
    reference: RasterAssetReference
  ) throws -> Data {
    let expectedByteCount: Int
    do {
      expectedByteCount = try byteCount(width: reference.width, height: reference.height)
    } catch {
      throw PixeltjeMacError(
        "Raster asset unsupported",
        "This project raster has invalid dimensions."
      )
    }
    let isImage = reference.pixelFormat == "rgba16FloatPremultiplied"
      && reference.colorSpace == "extendedLinearDisplayP3"
    let isInpaintAnalysis = reference.pixelFormat == RasterAssetReference.inpaintAnalysisPixelFormat
      && reference.colorSpace == "none"
    guard reference.formatVersion == RasterAssetReference.currentFormatVersion,
      (isImage || isInpaintAnalysis),
      reference.uncompressedByteCount == expectedByteCount
    else {
      throw PixeltjeMacError(
        "Raster asset unsupported",
        "This project raster uses an unsupported format or invalid dimensions."
      )
    }
    let pixels: Data
    do {
      pixels = try (compressedPixels as NSData).decompressed(using: .lzfse) as Data
    } catch {
      throw PixeltjeMacError(
        "Raster asset damaged",
        "The project raster could not be decompressed."
      )
    }
    guard pixels.count == expectedByteCount, sha256(pixels) == reference.id.rawValue else {
      throw PixeltjeMacError(
        "Raster asset damaged",
        "The project raster does not match the identity recorded in the recipe."
      )
    }
    return pixels
  }

  private static func byteCount(width: Int, height: Int) throws -> Int {
    guard width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
    let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
    let (byteCount, byteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 8)
    guard !pixelCountOverflow, !byteCountOverflow else {
      throw CocoaError(.fileReadTooLarge)
    }
    return byteCount
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
