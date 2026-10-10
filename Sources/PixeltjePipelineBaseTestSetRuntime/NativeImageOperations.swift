import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// This adapter uses premultiplied, display-referred sRGB values between image
/// nodes. Core Image converts tagged source media into that space on decode.
enum NativeImageColor {
  /// Core Image contexts are safe to reuse across executions; filters remain
  /// local to each operation because they are mutable.
  private final class ColorResources: @unchecked Sendable {
    let workingSpace: CGColorSpace
    let context: CIContext

    init?() {
      guard let workingSpace = CGColorSpace(name: CGColorSpace.sRGB)
      else { return nil }
      self.workingSpace = workingSpace
      context = CIContext(options: [
        .workingColorSpace: workingSpace,
        .outputPremultiplied: true,
      ])
    }
  }

  private static let resources = ColorResources()

  static func image(from output: CIImage, width: Int, height: Int) throws -> BaseTestSetImage {
    try BaseTestSetImage.validateDimensions(width: width, height: height)
    guard let resources
    else { throw BaseTestSetError.invalid("Required Apple color spaces are unavailable.") }
    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      resources.context.render(output, toBitmap: buffer.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBAf, colorSpace: resources.workingSpace)
    }
    return try BaseTestSetImage(width: width, height: height, rgba: pixels)
  }

  static func normalizedRGBA(width: Int, height: Int, sRGBBytes: [UInt8]) throws -> [Float] {
    guard let sourceSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let resources
    else { throw BaseTestSetError.invalid("Required Apple color spaces are unavailable.") }
    try BaseTestSetImage.validateDimensions(width: width, height: height)
    guard sRGBBytes.count == width * height * 4 else {
      throw BaseTestSetError.invalid("Invalid sRGB image buffer.")
    }
    let source = CIImage(
      bitmapData: Data(sRGBBytes), bytesPerRow: width * 4,
      size: CGSize(width: width, height: height),
      format: .RGBA8, colorSpace: sourceSpace)
    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      resources.context.render(source, toBitmap: buffer.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBAf, colorSpace: resources.workingSpace)
    }
    return pixels
  }

  static func image(width: Int, height: Int, normalizedRGBA pixels: [Float]) throws -> BaseTestSetImage {
    var quantized = pixels
    for index in quantized.indices {
      let bounded = min(max(Double(quantized[index]), 0), 1)
      quantized[index] = Float((bounded * 255).rounded()) / 255
    }
    return try BaseTestSetImage(width: width, height: height, rgba: quantized)
  }

  static func sRGBBytes(_ image: BaseTestSetImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for index in bytes.indices {
      let bounded = min(max(Double(image.rgba[index]), 0), 1)
      bytes[index] = UInt8((bounded * 255).rounded())
    }
    return bytes
  }

  static func ciImage(_ image: BaseTestSetImage) throws -> CIImage {
    guard let resources else {
      throw BaseTestSetError.invalid("sRGB is unavailable.")
    }
    return CIImage(bitmapData: image.rgba.withUnsafeBytes { Data($0) },
      bytesPerRow: image.width * 4 * MemoryLayout<Float>.size,
      size: CGSize(width: image.width, height: image.height), format: .RGBAf,
      colorSpace: resources.workingSpace)
  }
}

extension BaseTestSetImage {
  func invertedSRGB() throws -> Self {
    let source = rgba
    var output = source
    for offset in stride(from: 0, to: source.count, by: 4) {
      let alpha = max(source[offset + 3], 0)
      for channel in 0..<3 {
        output[offset + channel] = alpha - source[offset + channel]
      }
    }
    return try NativeImageColor.image(width: width, height: height, normalizedRGBA: output)
  }

  func fillingSRGB(mask: BaseTestSetMask, value: Double) throws -> Self {
    guard width == mask.width, height == mask.height,
      value.isFinite, (0...1).contains(value) else {
      throw BaseTestSetError.invalid("Fill mask or value is invalid.")
    }
    let source = rgba
    var output = source
    for pixel in 0..<(width * height) {
      let offset = pixel * 4
      let coverage = Double(mask.values[pixel])
      let alpha = Double(source[offset + 3])
      for channel in 0..<3 {
        output[offset + channel] = Float(
          Double(source[offset + channel]) * (1 - coverage)
            + value * alpha * coverage)
      }
    }
    return try NativeImageColor.image(width: width, height: height, normalizedRGBA: output)
  }

  func blendedSRGB(with other: Self, factor: Double, mode: String) throws -> Self {
    guard factor.isFinite, (0...1).contains(factor),
      ["normal", "multiply", "screen", "overlay", "soft_light", "difference"].contains(mode)
    else { throw BaseTestSetError.invalid("Blend factor or mode is invalid.") }
    let aligned = width == other.width && height == other.height
      ? other : try other.resized(to: width, height, method: "bicubic", crop: "center")
    let first = rgba
    let second = aligned.rgba
    var output = first
    for pixel in 0..<(width * height) {
      let offset = pixel * 4
      let alphaA = max(Double(first[offset + 3]), 0)
      let alphaB = max(Double(second[offset + 3]), 0)
      for channel in 0..<3 {
        let a = alphaA > 0 ? Double(first[offset + channel]) / alphaA : 0
        let b = alphaB > 0 ? Double(second[offset + channel]) / alphaB : 0
        let blend: Double
        switch mode {
        case "multiply": blend = a * b
        case "screen": blend = 1 - (1 - a) * (1 - b)
        case "overlay": blend = a <= 0.5 ? 2 * a * b : 1 - 2 * (1 - a) * (1 - b)
        case "soft_light":
          let g = a <= 0.25 ? ((16 * a - 12) * a + 4) * a : sqrt(max(a, 0))
          blend = b <= 0.5 ? a - (1 - 2 * b) * a * (1 - a)
            : a + (2 * b - 1) * (g - a)
        case "difference": blend = abs(a - b)
        default: blend = b
        }
        output[offset + channel] = Float(max(0, a * (1 - factor) + blend * factor)
          * alphaA)
      }
    }
    return try NativeImageColor.image(width: width, height: height, normalizedRGBA: output)
  }

  func compositingSRGB(_ source: Self, through mask: BaseTestSetMask?,
                         x: Int, y: Int, resizeSource: Bool) throws -> Self {
    let placed = resizeSource && (source.width != width || source.height != height)
      ? try source.resized(to: width, height, method: "bilinear") : source
    let coverage: BaseTestSetMask?
    if let mask {
      guard mask.width == source.width && mask.height == source.height else {
        throw BaseTestSetError.invalid("Composite mask must match source dimensions.")
      }
      coverage = resizeSource && (source.width != width || source.height != height)
        ? try mask.resized(to: width, height: height) : mask
    } else { coverage = nil }
    let destinationPixels = rgba
    let sourcePixels = placed.rgba
    var output = destinationPixels
    for sourceY in 0..<placed.height {
      let targetY = y + sourceY
      guard (0..<height).contains(targetY) else { continue }
      for sourceX in 0..<placed.width {
        let targetX = x + sourceX
        guard (0..<width).contains(targetX) else { continue }
        let sourceIndex = sourceY * placed.width + sourceX
        let targetIndex = targetY * width + targetX
        let sourceOffset = sourceIndex * 4
        let targetOffset = targetIndex * 4
        let maskValue = Double(coverage?.values[sourceIndex] ?? 1)
        let sourceAlpha = Double(sourcePixels[sourceOffset + 3]) * maskValue
        for channel in 0..<3 {
          output[targetOffset + channel] = Float(
            Double(sourcePixels[sourceOffset + channel]) * maskValue
              + Double(destinationPixels[targetOffset + channel]) * (1 - sourceAlpha))
        }
        output[targetOffset + 3] = Float(sourceAlpha
          + Double(destinationPixels[targetOffset + 3]) * (1 - sourceAlpha))
      }
    }
    return try NativeImageColor.image(width: width, height: height, normalizedRGBA: output)
  }

  func resized(to targetWidth: Int, _ targetHeight: Int,
               method: String, crop: String = "disabled") throws -> Self {
    guard targetWidth > 0, targetHeight > 0,
      targetWidth <= 8192, targetHeight <= 8192,
      targetWidth * targetHeight <= Self.maxPixelCount else {
      throw BaseTestSetError.invalid("Scaled image dimensions are out of range.")
    }
    guard crop == "disabled" || crop == "center" else {
      throw BaseTestSetError.invalid("Unsupported image crop mode \(crop).")
    }
    guard ["nearest-exact", "bilinear", "bicubic", "lanczos", "area"].contains(method) else {
      throw BaseTestSetError.invalid("Unsupported image scaling method \(method).")
    }
    if targetWidth == width, targetHeight == height, crop == "disabled" { return self }
    if method == "nearest-exact", crop == "disabled" {
      return try scaled(to: targetWidth, targetHeight)
    }
    if crop == "disabled", method == "lanczos" || method == "bicubic" {
      let input = try NativeImageColor.ciImage(self)
      let verticalScale = Float(Double(targetHeight) / Double(height))
      let horizontalScale = Float(Double(targetWidth) / Double(width))
      let output: CIImage?
      if method == "lanczos" {
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = input
        filter.scale = verticalScale
        filter.aspectRatio = horizontalScale / verticalScale
        output = filter.outputImage
      } else {
        let filter = CIFilter.bicubicScaleTransform()
        filter.inputImage = input
        filter.scale = verticalScale
        filter.aspectRatio = horizontalScale / verticalScale
        filter.parameterB = 0
        filter.parameterC = 0.5
        output = filter.outputImage
      }
      guard let output else {
        throw BaseTestSetError.invalid("Core Image could not scale the image.")
      }
      return try NativeImageColor.image(from: output,
        width: targetWidth, height: targetHeight)
    }
    let source = rgba
    var output = [Float](repeating: 0, count: targetWidth * targetHeight * 4)
    let scale = crop == "center"
      ? max(Double(targetWidth) / Double(width), Double(targetHeight) / Double(height))
      : 0
    let sourcePerTargetX = crop == "center" ? 1 / scale : Double(width) / Double(targetWidth)
    let sourcePerTargetY = crop == "center" ? 1 / scale : Double(height) / Double(targetHeight)
    let xOffset = crop == "center" ? (Double(width) - Double(targetWidth) / scale) / 2 : 0
    let yOffset = crop == "center" ? (Double(height) - Double(targetHeight) / scale) / 2 : 0
    for y in 0..<targetHeight {
      let centerY = (Double(y) + 0.5) * sourcePerTargetY - 0.5 + yOffset
      for x in 0..<targetWidth {
        let centerX = (Double(x) + 0.5) * sourcePerTargetX - 0.5 + xOffset
        let target = (y * targetWidth + x) * 4
        for channel in 0..<4 {
          let value: Double
          if method == "area", sourcePerTargetX > 1 || sourcePerTargetY > 1 {
            value = areaSample(source, x: centerX, y: centerY,
              footprintX: sourcePerTargetX, footprintY: sourcePerTargetY, channel: channel)
          } else {
            value = kernelSample(source, x: centerX, y: centerY,
              channel: channel, method: method == "area" ? "bilinear" : method)
          }
          output[target + channel] = Float(value)
        }
      }
    }
    return try NativeImageColor.image(width: targetWidth, height: targetHeight,
      normalizedRGBA: output)
  }

  func canny(lowThreshold: Double, highThreshold: Double) throws -> Self {
    guard lowThreshold.isFinite, highThreshold.isFinite,
      (0...1).contains(lowThreshold), (0...1).contains(highThreshold),
      lowThreshold <= highThreshold else {
      throw BaseTestSetError.invalid("Canny thresholds must satisfy 0 ≤ low ≤ high ≤ 1.")
    }
    let input = try NativeImageColor.ciImage(self)
    let filter = CIFilter.cannyEdgeDetector()
    filter.inputImage = input
    filter.gaussianSigma = 1.6
    filter.perceptual = false
    // Preserve the graph's 0...1 threshold values. Apple's gradient scale and
    // hysteresis behavior are not guaranteed to match ComfyUI pixel for pixel.
    filter.thresholdLow = Float(lowThreshold)
    filter.thresholdHigh = Float(highThreshold)
    filter.hysteresisPasses = 20
    guard let output = filter.outputImage else {
      throw BaseTestSetError.invalid("Core Image could not produce Canny edges.")
    }
    return try NativeImageColor.image(from: output, width: width, height: height)
  }

  private func channel(_ pixels: [Float], x: Int, y: Int, _ channel: Int) -> Double {
    let px = min(max(x, 0), width - 1)
    let py = min(max(y, 0), height - 1)
    return Double(pixels[(py * width + px) * 4 + channel])
  }

  private func kernelSample(_ pixels: [Float], x: Double, y: Double,
                            channel component: Int, method: String) -> Double {
    if method == "nearest-exact" {
      return channel(pixels, x: Int((x + 0.5).rounded(.down)),
        y: Int((y + 0.5).rounded(.down)), component)
    }
    let radius = method == "bilinear" ? 1 : method == "bicubic" ? 2 : 3
    let firstX = Int(floor(x)) - radius + 1
    let firstY = Int(floor(y)) - radius + 1
    var total = 0.0, weightTotal = 0.0
    for sy in firstY...(Int(floor(y)) + radius) {
      let wy = kernel(y - Double(sy), method: method)
      for sx in firstX...(Int(floor(x)) + radius) {
        let weight = wy * kernel(x - Double(sx), method: method)
        total += channel(pixels, x: sx, y: sy, component) * weight
        weightTotal += weight
      }
    }
    return weightTotal == 0 ? 0 : total / weightTotal
  }

  private func kernel(_ distance: Double, method: String) -> Double {
    let x = abs(distance)
    switch method {
    case "bilinear": return max(0, 1 - x)
    case "bicubic":
      if x < 1 { return (1.5 * x - 2.5) * x * x + 1 }
      if x < 2 { return ((-0.5 * x + 2.5) * x - 4) * x + 2 }
      return 0
    default:
      guard x < 3 else { return 0 }
      if x == 0 { return 1 }
      let p = Double.pi * x
      return 3 * sin(p) * sin(p / 3) / (p * p)
    }
  }

  private func areaSample(_ pixels: [Float], x: Double, y: Double,
                          footprintX: Double, footprintY: Double,
                          channel component: Int) -> Double {
    let left = x + 0.5 - footprintX / 2
    let right = x + 0.5 + footprintX / 2
    let top = y + 0.5 - footprintY / 2
    let bottom = y + 0.5 + footprintY / 2
    var sum = 0.0, area = 0.0
    for sy in Int(floor(top))..<Int(ceil(bottom)) {
      let overlapY = max(0, min(bottom, Double(sy + 1)) - max(top, Double(sy)))
      for sx in Int(floor(left))..<Int(ceil(right)) {
        let weight = overlapY * max(0, min(right, Double(sx + 1)) - max(left, Double(sx)))
        sum += channel(pixels, x: sx, y: sy, component) * weight
        area += weight
      }
    }
    return area == 0 ? 0 : sum / area
  }
}

extension BaseTestSetMask {
  func resized(to newWidth: Int, height newHeight: Int) throws -> Self {
    var result = try Self(width: newWidth, height: newHeight, value: 0)
    for y in 0..<newHeight {
      let sourceY = (Double(y) + 0.5) * Double(height) / Double(newHeight) - 0.5
      let y0 = Int(floor(sourceY)), y1 = y0 + 1
      let fy = Float(sourceY - Double(y0))
      for x in 0..<newWidth {
        let sourceX = (Double(x) + 0.5) * Double(width) / Double(newWidth) - 0.5
        let x0 = Int(floor(sourceX)), x1 = x0 + 1
        let fx = Float(sourceX - Double(x0))
        func sample(_ x: Int, _ y: Int) -> Float {
          values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        let top = sample(x0, y0) * (1 - fx) + sample(x1, y0) * fx
        let bottom = sample(x0, y1) * (1 - fx) + sample(x1, y1) * fx
        result.values[y * newWidth + x] = top * (1 - fy) + bottom * fy
      }
    }
    return result
  }
}
