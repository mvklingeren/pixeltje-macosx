import Foundation

/// Sampler inpaint coverage attached to a latent (ComfyUI `noise_mask`). It
/// stays at the resolution it was supplied at; the sampler that consumes it
/// resizes it to the latent. One means the sampler may change the cell.
public struct PipelineLatentNoiseMask: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let coverage: [Float]

  public init(width: Int, height: Int, coverage: [Float]) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, coverage.count == pixels,
      coverage.allSatisfy({ $0.isFinite && (0...1).contains($0) })
    else {
      throw PipelineOperationError.invalidArgument("Invalid latent noise mask.")
    }
    self.width = width
    self.height = height
    self.coverage = coverage
  }
}

/// A latent batch (ComfyUI `LATENT`) in batch, channel, [frame,] row, column
/// order. Model adapters own the meaning of the channels; the operations here
/// are the model-free batch, shape and resampling nodes.
public struct PipelineLatent: Equatable, Sendable {
  /// Upper bound for materialized samples: 256 MB of `Float`.
  public static let maximumMaterializedCount = 64 * 1024 * 1024
  /// Upper bound for a described shape. All-zero latents are not materialized.
  public static let maximumElementCount = Int(Int32.max)
  public static let maximumBatchSize = 4096
  public static let resamplingMethods = ["nearest-exact", "bilinear", "area", "bicubic", "bislerp"]

  public private(set) var batchSize: Int
  /// Channel count, or nil for an all-zero latent whose channel count the
  /// consuming model decides. ComfyUI resolves an empty latent's channels
  /// the same way, which lets one Empty Latent Image serve every image model.
  public private(set) var channels: Int?
  /// Latent frames for a video latent; nil for an image latent.
  public private(set) var frames: Int?
  public private(set) var height: Int
  public private(set) var width: Int
  /// Pixels per latent cell along each spatial axis.
  public private(set) var spatialScale: Int
  /// Samples in storage order, or nil when every sample is zero.
  public private(set) var samples: [Float]?
  public var noiseMask: PipelineLatentNoiseMask?
  /// Positions of these items in the batch they were selected from. A sampler
  /// uses them to give a selected item the noise it would get in that batch.
  public private(set) var batchIndices: [Int]?

  /// An all-zero latent. Pixel dimensions round down to whole latent cells.
  public static func zeros(
    pixelWidth: Int,
    pixelHeight: Int,
    spatialScale: Int,
    channels: Int?,
    frames: Int? = nil,
    batchSize: Int
  ) throws -> PipelineLatent {
    guard spatialScale > 0, pixelWidth >= spatialScale, pixelHeight >= spatialScale,
      pixelWidth <= 16384, pixelHeight <= 16384
    else {
      throw PipelineOperationError.invalidArgument(
        "Latent pixel dimensions must be \(spatialScale)–16384.")
    }
    return try PipelineLatent(
      batchSize: batchSize, channels: channels, frames: frames,
      height: pixelHeight / spatialScale, width: pixelWidth / spatialScale,
      spatialScale: spatialScale, samples: nil)
  }

  public init(
    batchSize: Int,
    channels: Int?,
    frames: Int? = nil,
    height: Int,
    width: Int,
    spatialScale: Int,
    samples: [Float]?,
    noiseMask: PipelineLatentNoiseMask? = nil,
    batchIndices: [Int]? = nil
  ) throws {
    guard (1...Self.maximumBatchSize).contains(batchSize) else {
      throw PipelineOperationError.invalidArgument(
        "Latent batch size must be 1–\(Self.maximumBatchSize).")
    }
    guard channels.map({ $0 > 0 }) ?? true, frames.map({ $0 > 0 }) ?? true,
      height > 0, width > 0, spatialScale > 0
    else {
      throw PipelineOperationError.invalidArgument("Latent dimensions must be positive.")
    }
    let count = Self.elementCount(
      batchSize: batchSize, channels: channels ?? 1, frames: frames ?? 1,
      height: height, width: width)
    guard let count, count <= Self.maximumElementCount else {
      throw PipelineOperationError.invalidArgument("Latent is too large.")
    }
    if let samples {
      guard channels != nil else {
        throw PipelineOperationError.invalidArgument(
          "A latent with samples needs a channel count.")
      }
      guard count <= Self.maximumMaterializedCount, samples.count == count,
        samples.allSatisfy(\.isFinite)
      else {
        throw PipelineOperationError.invalidArgument("Latent samples do not match its shape.")
      }
    }
    if let batchIndices, batchIndices.count != batchSize {
      throw PipelineOperationError.invalidArgument("Latent batch indices do not match its batch.")
    }
    self.batchSize = batchSize
    self.channels = channels
    self.frames = frames
    self.height = height
    self.width = width
    self.spatialScale = spatialScale
    self.samples = samples
    self.noiseMask = noiseMask
    self.batchIndices = batchIndices
  }

  /// Batch, channels, [frames,] height and width. Channels are nil while the
  /// consuming model still decides them.
  public var shape: [Int?] {
    var result: [Int?] = [batchSize, channels]
    if let frames { result.append(frames) }
    result += [height, width]
    return result
  }

  private var itemCount: Int { (channels ?? 1) * (frames ?? 1) * height * width }

  /// A zero latent of the same shape and scale. Masks and batch positions
  /// describe the source's content, so they are not carried over.
  public func zerosLike() -> PipelineLatent {
    var result = self
    result.samples = nil
    result.noiseMask = nil
    result.batchIndices = nil
    return result
  }

  /// Repeats the whole batch `amount` times. Batch positions continue after
  /// the source's range so every copy keeps distinct sampler noise.
  public func repeated(_ amount: Int) throws -> PipelineLatent {
    guard (1...64).contains(amount) else {
      throw PipelineOperationError.invalidArgument("Repeat amount must be 1–64.")
    }
    guard batchSize * amount <= Self.maximumBatchSize else {
      throw PipelineOperationError.invalidArgument(
        "Repeated latent batch exceeds \(Self.maximumBatchSize).")
    }
    var indices: [Int]?
    if let batchIndices, let low = batchIndices.min(), let high = batchIndices.max() {
      let offset = high - low + 1
      indices = (0..<amount).flatMap { copy in batchIndices.map { $0 + copy * offset } }
    }
    let repeatedSamples = try samples.map { values -> [Float] in
      guard values.count * amount <= Self.maximumMaterializedCount else {
        throw PipelineOperationError.invalidArgument("Repeated latent is too large.")
      }
      return Array((0..<amount).map { _ in values }.joined())
    }
    return try PipelineLatent(
      batchSize: batchSize * amount, channels: channels, frames: frames,
      height: height, width: width, spatialScale: spatialScale,
      samples: repeatedSamples, noiseMask: noiseMask, batchIndices: indices)
  }

  /// Selects consecutive batch items. Negative indices count from the end;
  /// an index or length past the end is clamped to the batch, as in ComfyUI.
  public func selectingBatch(from index: Int, length: Int) throws -> PipelineLatent {
    guard length >= 1 else {
      throw PipelineOperationError.invalidArgument(
        "Latent batch length must be at least one.")
    }
    let resolvedIndex = index < 0 ? index + batchSize : index
    let start = max(0, min(batchSize - 1, resolvedIndex))
    let count = min(batchSize - start, length)
    let selected = samples.map {
      Array($0[(start * itemCount)..<((start + count) * itemCount)])
    }
    return try PipelineLatent(
      batchSize: count, channels: channels, frames: frames,
      height: height, width: width, spatialScale: spatialScale,
      samples: selected, noiseMask: noiseMask,
      batchIndices: batchIndices.map { Array($0[start..<(start + count)]) }
        ?? Array(start..<(start + count)))
  }

  /// Resamples every frame to `width` × `height` latent cells. A `center`
  /// crop first trims the source to the target aspect ratio. The noise mask
  /// keeps its own resolution; batch positions are unchanged.
  public func resized(
    width newWidth: Int, height newHeight: Int, method: String, crop: String = "disabled"
  ) throws -> PipelineLatent {
    guard Self.resamplingMethods.contains(method) else {
      throw PipelineOperationError.invalidArgument("Unsupported latent upscale method \(method).")
    }
    guard crop == "disabled" || crop == "center" else {
      throw PipelineOperationError.invalidArgument("Unsupported latent crop \(crop).")
    }
    guard newWidth > 0, newHeight > 0 else {
      throw PipelineOperationError.invalidArgument("Scaled latent must be at least one cell.")
    }
    guard let outputCount = Self.elementCount(
      batchSize: batchSize, channels: channels ?? 1, frames: frames ?? 1,
      height: newHeight, width: newWidth),
      outputCount <= (samples == nil ? Self.maximumElementCount : Self.maximumMaterializedCount)
    else {
      throw PipelineOperationError.invalidArgument("Scaled latent is too large.")
    }
    var result = self
    result.width = newWidth
    result.height = newHeight
    guard let samples, let channels else { return result }

    var cropX = 0
    var cropY = 0
    if crop == "center" {
      let oldAspect = Double(width) / Double(height)
      let newAspect = Double(newWidth) / Double(newHeight)
      if oldAspect > newAspect {
        cropX = Int(((Double(width) - Double(width) * (newAspect / oldAspect)) / 2)
          .rounded(.toNearestOrEven))
      } else if oldAspect < newAspect {
        cropY = Int(((Double(height) - Double(height) * (oldAspect / newAspect)) / 2)
          .rounded(.toNearestOrEven))
      }
    }
    let sourceWidth = width - 2 * cropX
    let sourceHeight = height - 2 * cropY
    guard sourceWidth > 0, sourceHeight > 0 else {
      throw PipelineOperationError.invalidArgument("Center crop leaves no latent cells.")
    }

    let planes = batchSize * (frames ?? 1)
    let frameCount = frames ?? 1
    // Gathers each (item, frame) as channel planes of the cropped source.
    func sourcePlanes(_ plane: Int) -> [[Float]] {
      let item = plane / frameCount
      let frame = plane % frameCount
      return (0..<channels).map { channel in
        let base = ((item * channels + channel) * frameCount + frame) * height * width
        var values = [Float](repeating: 0, count: sourceWidth * sourceHeight)
        for row in 0..<sourceHeight {
          let sourceRow = base + (row + cropY) * width + cropX
          for column in 0..<sourceWidth {
            values[row * sourceWidth + column] = samples[sourceRow + column]
          }
        }
        return values
      }
    }

    var output = [Float](repeating: 0, count: outputCount)
    for plane in 0..<planes {
      let item = plane / frameCount
      let frame = plane % frameCount
      let source = sourcePlanes(plane)
      let resampled: [[Float]]
      if method == "bislerp" {
        resampled = Self.bislerp(
          source, width: sourceWidth, height: sourceHeight,
          toWidth: newWidth, height: newHeight)
      } else {
        let horizontal = Self.weights(from: sourceWidth, to: newWidth, method: method)
        let vertical = Self.weights(from: sourceHeight, to: newHeight, method: method)
        resampled = source.map {
          Self.resample(
            $0, width: sourceWidth, height: sourceHeight,
            horizontal: horizontal, vertical: vertical)
        }
      }
      for channel in 0..<channels {
        let base = ((item * channels + channel) * frameCount + frame) * newHeight * newWidth
        output.replaceSubrange(base..<(base + newHeight * newWidth), with: resampled[channel])
      }
    }
    result.samples = output
    return result
  }

  private static func elementCount(
    batchSize: Int, channels: Int, frames: Int, height: Int, width: Int
  ) -> Int? {
    var count = 1
    for factor in [batchSize, channels, frames, height, width] {
      let (product, overflow) = count.multipliedReportingOverflow(by: factor)
      guard !overflow else { return nil }
      count = product
    }
    return count
  }

  private typealias Taps = [(index: Int, weight: Double)]

  /// One-dimensional tap tables matching PyTorch `interpolate` with
  /// `align_corners=False`. Every supported mode is separable.
  private static func weights(from input: Int, to output: Int, method: String) -> [Taps] {
    let scale = Double(input) / Double(output)
    return (0..<output).map { position -> Taps in
      switch method {
      case "nearest-exact":
        let source = Int(((Double(position) + 0.5) * scale).rounded(.down))
        return [(min(source, input - 1), 1)]
      case "bilinear":
        let source = max((Double(position) + 0.5) * scale - 0.5, 0)
        let lower = min(Int(source), input - 1)
        let upper = lower < input - 1 ? lower + 1 : lower
        let fraction = source - Double(lower)
        return [(lower, 1 - fraction), (upper, fraction)]
      case "bicubic":
        let source = (Double(position) + 0.5) * scale - 0.5
        let floorValue = source.rounded(.down)
        let t = source - floorValue
        let a = -0.75
        func near(_ x: Double) -> Double { ((a + 2) * x - (a + 3)) * x * x + 1 }
        func far(_ x: Double) -> Double { ((a * x - 5 * a) * x + 8 * a) * x - 4 * a }
        let coefficients = [far(t + 1), near(t), near(1 - t), far(2 - t)]
        let first = Int(floorValue) - 1
        return (0..<4).map { tap in
          (min(max(first + tap, 0), input - 1), coefficients[tap])
        }
      default:  // area: PyTorch adaptive average pooling.
        let start = position * input / output
        let end = ((position + 1) * input + output - 1) / output
        let weight = 1 / Double(end - start)
        return (start..<end).map { ($0, weight) }
      }
    }
  }

  private static func resample(
    _ plane: [Float], width: Int, height: Int, horizontal: [Taps], vertical: [Taps]
  ) -> [Float] {
    let newWidth = horizontal.count
    var rows = [Double](repeating: 0, count: height * newWidth)
    for row in 0..<height {
      for column in 0..<newWidth {
        var sum = 0.0
        for tap in horizontal[column] {
          sum += Double(plane[row * width + tap.index]) * tap.weight
        }
        rows[row * newWidth + column] = sum
      }
    }
    var result = [Float](repeating: 0, count: vertical.count * newWidth)
    for row in 0..<vertical.count {
      for column in 0..<newWidth {
        var sum = 0.0
        for tap in vertical[row] { sum += rows[tap.index * newWidth + column] * tap.weight }
        result[row * newWidth + column] = Float(sum)
      }
    }
    return result
  }

  /// ComfyUI's bislerp: spherical interpolation of each cell's channel vector
  /// between its two bilinear neighbours, first along rows, then columns.
  private static func bislerp(
    _ planes: [[Float]], width: Int, height: Int, toWidth newWidth: Int, height newHeight: Int
  ) -> [[Float]] {
    let channels = planes.count
    let horizontal = slerpCoordinates(from: width, to: newWidth)
    var pass = [[Float]](
      repeating: [Float](repeating: 0, count: height * newWidth), count: channels)
    var first = [Float](repeating: 0, count: channels)
    var second = [Float](repeating: 0, count: channels)
    for row in 0..<height {
      for column in 0..<newWidth {
        let coordinate = horizontal[column]
        for channel in 0..<channels {
          first[channel] = planes[channel][row * width + coordinate.first]
          second[channel] = planes[channel][row * width + coordinate.second]
        }
        let value = slerp(first, second, ratio: coordinate.ratio)
        for channel in 0..<channels { pass[channel][row * newWidth + column] = value[channel] }
      }
    }
    let vertical = slerpCoordinates(from: height, to: newHeight)
    var result = [[Float]](
      repeating: [Float](repeating: 0, count: newHeight * newWidth), count: channels)
    for row in 0..<newHeight {
      let coordinate = vertical[row]
      for column in 0..<newWidth {
        for channel in 0..<channels {
          first[channel] = pass[channel][coordinate.first * newWidth + column]
          second[channel] = pass[channel][coordinate.second * newWidth + column]
        }
        let value = slerp(first, second, ratio: coordinate.ratio)
        for channel in 0..<channels { result[channel][row * newWidth + column] = value[channel] }
      }
    }
    return result
  }

  /// Bilinearly resampled neighbour indices and blend ratio for each output
  /// position, as ComfyUI derives them from interpolated coordinate ramps.
  private static func slerpCoordinates(
    from input: Int, to output: Int
  ) -> [(first: Int, second: Int, ratio: Float)] {
    weights(from: input, to: output, method: "bilinear").map { taps in
      let lower = taps[0].index
      let ratio = taps[1].index == lower ? 0 : Float(taps[1].weight)
      return (lower, min(lower + 1, input - 1), ratio)
    }
  }

  private static func slerp(_ first: [Float], _ second: [Float], ratio: Float) -> [Float] {
    func norm(_ vector: [Float]) -> Float { sqrt(vector.reduce(0) { $0 + $1 * $1 }) }
    let firstNorm = norm(first)
    let secondNorm = norm(second)
    let firstUnit = first.map { firstNorm == 0 ? 0 : $0 / firstNorm }
    let secondUnit = second.map { secondNorm == 0 ? 0 : $0 / secondNorm }
    let dot = zip(firstUnit, secondUnit).reduce(0) { $0 + $1.0 * $1.1 }
    if dot > 1 - 1e-5 { return first }
    if dot < 1e-5 - 1 {
      return zip(first, second).map { $0 * (1 - ratio) + $1 * ratio }
    }
    let omega = acos(dot)
    let sine = sin(omega)
    let firstWeight = sin((1 - ratio) * omega) / sine
    let secondWeight = sin(ratio * omega) / sine
    let magnitude = firstNorm * (1 - ratio) + secondNorm * ratio
    return zip(firstUnit, secondUnit).map {
      (firstWeight * $0 + secondWeight * $1) * magnitude
    }
  }
}

extension PipelineLatent {
  /// ComfyUI's EmptyLatentImage and EmptySD3LatentImage: 8× spatial
  /// compression, with the channel count left to the consuming model.
  public static func emptyImage(width: Int, height: Int, batchSize: Int) throws -> Self {
    try zeros(
      pixelWidth: width, pixelHeight: height, spatialScale: 8, channels: nil,
      batchSize: batchSize)
  }

  /// FLUX.2's packed latent: 128 channels at 16× spatial compression.
  public static func emptyFLUX2Image(width: Int, height: Int, batchSize: Int) throws -> Self {
    try zeros(
      pixelWidth: width, pixelHeight: height, spatialScale: 16, channels: 128,
      batchSize: batchSize)
  }

  /// Hunyuan Video: 16 channels, 8× spatial and 4× temporal compression.
  public static func emptyHunyuanVideo(
    width: Int, height: Int, length: Int, batchSize: Int
  ) throws -> Self {
    try zeros(
      pixelWidth: width, pixelHeight: height, spatialScale: 8, channels: 16,
      frames: videoFrames(length: length, temporalScale: 4), batchSize: batchSize)
  }

  /// LTX-Video: 128 channels, 32× spatial and 8× temporal compression.
  public static func emptyLTXVVideo(
    width: Int, height: Int, length: Int, batchSize: Int
  ) throws -> Self {
    try zeros(
      pixelWidth: width, pixelHeight: height, spatialScale: 32, channels: 128,
      frames: videoFrames(length: length, temporalScale: 8), batchSize: batchSize)
  }

  /// Causal video VAEs keep the first frame and compress the rest.
  private static func videoFrames(length: Int, temporalScale: Int) throws -> Int {
    guard (1...16384).contains(length) else {
      throw PipelineOperationError.invalidArgument("Video length must be 1–16384 frames.")
    }
    return (length - 1) / temporalScale + 1
  }
}
