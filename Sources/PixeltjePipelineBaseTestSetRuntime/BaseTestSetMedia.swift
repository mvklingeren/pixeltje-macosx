import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import PixeltjePipelineEngine

enum BaseTestSetError: Error, LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    guard case .invalid(let message) = self else { return nil }
    return message
  }
}

struct BaseTestSetImage: Sendable {
  static let maxPixelCount = 16 * 1024 * 1024

  let width: Int
  let height: Int
  /// Premultiplied display-referred sRGB RGBA, normalized to floating-point
  /// component values. This is the Base Test Set ABI's image value space.
  var rgba: [Float]

  static func validateDimensions(width: Int, height: Int) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, pixels <= Int.max / 16 else {
      throw BaseTestSetError.invalid("Image dimensions need a representable RGBA buffer.")
    }
  }

  init(width: Int, height: Int, fill: (Float, Float, Float, Float) = (0, 0, 0, 1)) throws {
    try Self.validateDimensions(width: width, height: height)
    self.width = width
    self.height = height
    rgba = [Float](repeating: 0, count: width * height * 4)
    for pixel in 0..<(width * height) {
      let offset = pixel * 4
      rgba[offset] = fill.0
      rgba[offset + 1] = fill.1
      rgba[offset + 2] = fill.2
      rgba[offset + 3] = fill.3
    }
  }

  init(width: Int, height: Int, rgba: [Float]) throws {
    try Self.validateDimensions(width: width, height: height)
    guard rgba.count == width * height * 4, rgba.allSatisfy(\.isFinite)
    else { throw BaseTestSetError.invalid("Invalid RGBA image buffer.") }
    self.width = width
    self.height = height
    self.rgba = rgba
  }

  init(width: Int, height: Int, sRGBBytes: [UInt8]) throws {
    let normalized = try NativeImageColor.normalizedRGBA(
      width: width, height: height, sRGBBytes: sRGBBytes)
    try self.init(width: width, height: height, rgba: normalized)
  }

  static func loadPNG(at url: URL) throws -> Self {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw BaseTestSetError.invalid("Could not decode image \(url.lastPathComponent).") }
    let width = image.width
    let height = image.height
    try Self.validateDimensions(width: width, height: height)
    return try NativeImageColor.image(from: CIImage(cgImage: image),
      width: width, height: height)
  }

  func writePNG(to url: URL) throws {
    let data = Data(try NativeImageColor.sRGBBytes(self))
    guard let provider = CGDataProvider(data: data as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw BaseTestSetError.invalid("Could not create output PNG.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw BaseTestSetError.invalid("Could not write output PNG.")
    }
  }

  func scaled(to newWidth: Int, _ newHeight: Int) throws -> Self {
    var result = try Self(width: newWidth, height: newHeight)
    for y in 0..<newHeight {
      let sourceY = min(height - 1, y * height / newHeight)
      for x in 0..<newWidth {
        let sourceX = min(width - 1, x * width / newWidth)
        let source = (sourceY * width + sourceX) * 4
        let target = (y * newWidth + x) * 4
        result.rgba[target..<(target + 4)] = rgba[source..<(source + 4)]
      }
    }
    return result
  }

  func cropped(x: Int, y: Int, width newWidth: Int, height newHeight: Int) throws -> Self {
    guard x >= 0, y >= 0, newWidth > 0, newHeight > 0,
      x + newWidth <= width, y + newHeight <= height
    else { throw BaseTestSetError.invalid("Crop is outside the source image.") }
    var result = try Self(width: newWidth, height: newHeight)
    for row in 0..<newHeight {
      let source = ((y + row) * width + x) * 4
      let target = row * newWidth * 4
      result.rgba[target..<(target + newWidth * 4)] = rgba[source..<(source + newWidth * 4)]
    }
    return result
  }

  func padded(left: Int, top: Int, right: Int, bottom: Int,
              feathering: Int) throws -> (Self, BaseTestSetMask) {
    guard [left, top, right, bottom, feathering].allSatisfy({ $0 >= 0 }) else {
      throw BaseTestSetError.invalid("Padding must be non-negative.")
    }
    let newWidth = width + left + right
    let newHeight = height + top + bottom
    var result = try Self(width: newWidth, height: newHeight,
      fill: (0.5, 0.5, 0.5, 1))
    var mask = try BaseTestSetMask(width: newWidth, height: newHeight, value: 1)
    for y in 0..<height {
      let source = y * width * 4
      let target = ((y + top) * newWidth + left) * 4
      result.rgba[target..<(target + width * 4)] = rgba[source..<(source + width * 4)]
      for x in 0..<width {
        let distance = min(min(x, y), min(width - 1 - x, height - 1 - y))
        let coverage = feathering > 0
          ? max(0, 1 - Float(distance + 1) / Float(feathering)) : 0
        mask.values[(y + top) * newWidth + x + left] = coverage
      }
    }
    return (result, mask)
  }

  func planarRGB() throws -> [Float] {
    let count = width * height
    var planar = [Float](repeating: 0, count: count * 3)
    for pixel in 0..<count {
      for channel in 0..<3 {
        let alpha = rgba[pixel * 4 + 3]
        planar[channel * count + pixel] = alpha > 0 ? rgba[pixel * 4 + channel] / alpha : 0
      }
    }
    return planar
  }

  var alpha: [Float]? {
    let values = (0..<(width * height)).map { rgba[$0 * 4 + 3] }
    return values.allSatisfy { $0 == 1 } ? nil : values
  }
}

struct BaseTestSetMask: Sendable {
  let width: Int
  let height: Int
  var values: [Float]

  init(host input: PipelineMaskInput) throws {
    try BaseTestSetImage.validateDimensions(width: input.width, height: input.height)
    width = input.width
    height = input.height
    values = input.coverage
  }

  init(width: Int, height: Int, value: Float) throws {
    try BaseTestSetImage.validateDimensions(width: width, height: height)
    self.width = width
    self.height = height
    values = [Float](repeating: value, count: width * height)
  }

  init(channel: String, of image: BaseTestSetImage) throws {
    let component: Int
    switch channel.lowercased() {
    case "red": component = 0
    case "green": component = 1
    case "blue": component = 2
    case "alpha": component = 3
    default: throw BaseTestSetError.invalid("Unsupported image mask channel \(channel).")
    }
    self = try Self(width: image.width, height: image.height, value: 0)
    for pixel in values.indices {
      let offset = pixel * 4
      let alpha = image.rgba[offset + 3]
      values[pixel] = component == 3 ? alpha
        : alpha > 0 ? image.rgba[offset + component] / alpha : 0
    }
  }

  func cropped(x: Int, y: Int, width newWidth: Int, height newHeight: Int) throws -> Self {
    guard x >= 0, y >= 0, newWidth > 0, newHeight > 0,
      x + newWidth <= width, y + newHeight <= height
    else { throw BaseTestSetError.invalid("Mask crop is outside the source.") }
    var result = try Self(width: newWidth, height: newHeight, value: 0)
    for row in 0..<newHeight {
      for column in 0..<newWidth {
        result.values[row * newWidth + column] = values[(y + row) * width + x + column]
      }
    }
    return result
  }

  func inverted() -> Self {
    var result = self
    for index in values.indices { result.values[index] = 1 - values[index] }
    return result
  }

  func compositing(_ source: Self, x: Int, y: Int, operation: String) throws -> Self {
    guard ["multiply", "add", "subtract", "and", "or", "xor"].contains(operation) else {
      throw BaseTestSetError.invalid("Unsupported mask operation \(operation).")
    }
    var result = self
    for sourceY in 0..<source.height {
      let targetY = y + sourceY
      guard (0..<height).contains(targetY) else { continue }
      for sourceX in 0..<source.width {
        let targetX = x + sourceX
        guard (0..<width).contains(targetX) else { continue }
        let index = targetY * width + targetX
        let a = values[index]
        let b = source.values[sourceY * source.width + sourceX]
        switch operation {
        case "multiply", "and": result.values[index] = a * b
        case "add": result.values[index] = min(1, a + b)
        case "subtract": result.values[index] = max(0, a - b)
        case "or": result.values[index] = max(a, b)
        case "xor": result.values[index] = abs(a - b)
        default: break
        }
      }
    }
    return result
  }

  func grown(by radius: Int, taperedCorners: Bool) throws -> Self {
    guard (-64...64).contains(radius) else {
      throw BaseTestSetError.invalid("Mask growth must be within 64 pixels.")
    }
    guard radius != 0 else { return self }
    let extent = abs(radius)
    let input = try NativeImageColor.ciImage(image())
    let output: CIImage?
    if taperedCorners {
      if radius > 0 {
        let filter = CIFilter.morphologyMaximum()
        filter.inputImage = input
        filter.radius = Float(extent)
        output = filter.outputImage
      } else {
        let filter = CIFilter.morphologyMinimum()
        filter.inputImage = input
        filter.radius = Float(extent)
        output = filter.outputImage
      }
    } else {
      if radius > 0 {
        let filter = CIFilter.morphologyRectangleMaximum()
        filter.inputImage = input
        filter.width = Float(extent * 2 + 1)
        filter.height = Float(extent * 2 + 1)
        output = filter.outputImage
      } else {
        let filter = CIFilter.morphologyRectangleMinimum()
        filter.inputImage = input
        filter.width = Float(extent * 2 + 1)
        filter.height = Float(extent * 2 + 1)
        output = filter.outputImage
      }
    }
    guard let output else {
      throw BaseTestSetError.invalid("Core Image could not grow the mask.")
    }
    let rendered = try NativeImageColor.image(from: output,
      width: width, height: height)
    var result = try Self(width: width, height: height, value: 0)
    for index in values.indices {
      result.values[index] = min(1, max(0, rendered.rgba[index * 4]))
    }
    return result
  }

  func feathered(left: Int, top: Int, right: Int, bottom: Int) throws -> Self {
    guard [left, top, right, bottom].allSatisfy({ (0...256).contains($0) }) else {
      throw BaseTestSetError.invalid("Mask feather radii must be within 256 pixels.")
    }
    guard left + top + right + bottom > 0 else { return self }
    var horizontal = [Float](repeating: 0, count: values.count)
    var result = try Self(width: width, height: height, value: 0)
    for y in 0..<height {
      for x in 0..<width {
        var sum: Float = 0
        for dx in -left...right {
          let sourceX = x + dx
          if (0..<width).contains(sourceX) { sum += values[y * width + sourceX] }
        }
        horizontal[y * width + x] = sum / Float(left + right + 1)
      }
    }
    for y in 0..<height {
      for x in 0..<width {
        var sum: Float = 0
        for dy in -top...bottom {
          let sourceY = y + dy
          if (0..<height).contains(sourceY) { sum += horizontal[sourceY * width + x] }
        }
        result.values[y * width + x] = sum / Float(top + bottom + 1)
      }
    }
    return result
  }

  func thresholded(at threshold: Float) -> Self {
    var result = self
    for index in values.indices { result.values[index] = values[index] > threshold ? 1 : 0 }
    return result
  }

  func image() throws -> BaseTestSetImage {
    var result = try BaseTestSetImage(width: width, height: height)
    for index in values.indices {
      let gray = values[index]
      let offset = index * 4
      result.rgba[offset] = gray
      result.rgba[offset + 1] = gray
      result.rgba[offset + 2] = gray
    }
    return result
  }
}

struct BaseTestSetVideo: Sendable {
  var frames: [BaseTestSetImage]
  var audioSource: URL?
  var framesPerSecond: Double
  var sourceURL: URL?
  var frameCount: Int
  var width: Int
  var height: Int

  init(frames: [BaseTestSetImage], audioSource: URL?, framesPerSecond: Double) {
    self.frames = frames
    self.audioSource = audioSource
    self.framesPerSecond = framesPerSecond
    sourceURL = nil
    frameCount = frames.count
    width = frames.first?.width ?? 0
    height = frames.first?.height ?? 0
  }

  init(sourceURL: URL, frameCount: Int, width: Int, height: Int,
       framesPerSecond: Double, hasAudio: Bool) {
    frames = []
    audioSource = hasAudio ? sourceURL : nil
    self.framesPerSecond = framesPerSecond
    self.sourceURL = sourceURL
    self.frameCount = frameCount
    self.width = width
    self.height = height
  }
}
