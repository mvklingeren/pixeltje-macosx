import Foundation

/// Guardrails for generated coverage. A captured contiguous region is compact
/// run-length geometry rather than an unbounded bitmap embedded in JSON.
public enum PaintOperationLimits {
  public static let maximumRasterAxis = 16_384
  public static let maximumRasterPixels = 16_777_216
  public static let maximumRasterRuns = 1_048_576
  public static let minimumPolygonSides = 3
  public static let maximumPolygonSides = 64
}

public struct RasterMaskRun: Codable, Equatable, Sendable {
  public var y: Int
  public var startX: Int
  public var length: Int
  /// Quantized mask coverage shared by every pixel in this run. Older project
  /// files omit it and therefore decode as the fully selected coverage they
  /// always represented.
  public var coverage: UInt8

  public init(y: Int, startX: Int, length: Int, coverage: UInt8 = .max) {
    self.y = max(y, 0)
    self.startX = max(startX, 0)
    self.length = max(length, 0)
    self.coverage = coverage
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      y: try values.decodeIfPresent(Int.self, forKey: .y) ?? 0,
      startX: try values.decodeIfPresent(Int.self, forKey: .startX) ?? 0,
      length: try values.decodeIfPresent(Int.self, forKey: .length) ?? 0,
      coverage: UInt8(clamping: try values.decodeIfPresent(Int.self, forKey: .coverage) ?? 255))
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(y, forKey: .y)
    try values.encode(startX, forKey: .startX)
    try values.encode(length, forKey: .length)
    if coverage != .max { try values.encode(coverage, forKey: .coverage) }
  }

  private enum CodingKeys: String, CodingKey { case y, startX, length, coverage }
}

/// Resolution-bound coverage produced by a contiguous bucket calculation.
/// Coordinates are scaled back onto the canonical canvas when evaluated.
public struct RasterMask: Codable, Equatable, Sendable {
  public var width: Int
  public var height: Int
  public var runs: [RasterMaskRun]

  public init(width: Int, height: Int, runs: [RasterMaskRun]) {
    let safeWidth = min(max(width, 0), PaintOperationLimits.maximumRasterAxis)
    let axisBoundedHeight = min(max(height, 0), PaintOperationLimits.maximumRasterAxis)
    let safeHeight = safeWidth > 0
      ? min(axisBoundedHeight, PaintOperationLimits.maximumRasterPixels / safeWidth)
      : 0
    self.width = safeWidth
    self.height = safeHeight
    self.runs = Array(
      runs.lazy.filter {
        $0.length > 0 && $0.coverage > 0 && $0.y < safeHeight && $0.startX < safeWidth
      }.map {
        RasterMaskRun(
          y: $0.y,
          startX: $0.startX,
          length: min($0.length, safeWidth - $0.startX),
          coverage: $0.coverage
        )
      }.prefix(PaintOperationLimits.maximumRasterRuns)
    )
  }

  public var isEmpty: Bool { width == 0 || height == 0 || runs.isEmpty }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let width = try values.decodeIfPresent(Int.self, forKey: .width) ?? 0
    let height = try values.decodeIfPresent(Int.self, forKey: .height) ?? 0
    var decoded: [RasterMaskRun] = []
    if var entries = try? values.nestedUnkeyedContainer(forKey: .runs) {
      while !entries.isAtEnd {
        let run = try entries.decode(RasterMaskRun.self)
        if decoded.count < PaintOperationLimits.maximumRasterRuns { decoded.append(run) }
      }
    }
    self.init(width: width, height: height, runs: decoded)
  }

  private enum CodingKeys: String, CodingKey { case width, height, runs }
}

/// Resolution-bound coverage placed over a specific part of the canvas.
/// A segmentation result can keep its native mask resolution even when the
/// document is much larger than the image sent to the model.
public struct PlacedRasterMask: Codable, Equatable, Sendable {
  public var raster: RasterMask
  public var frame: ShapeMask

  public init(raster: RasterMask, frame: ShapeMask) {
    self.raster = raster
    self.frame = frame
  }

  public var isEmpty: Bool { raster.isEmpty || frame.isEmpty }
}

public enum PaintGradientKind: String, Codable, CaseIterable, Sendable {
  case linear
  case radial

  public var label: String { self == .linear ? "Linear" : "Radial" }
}

/// Gradients interpolate straight components in Extended Linear Display P3.
/// The two colors therefore use the same type and pipeline as Brush paint.
public struct PaintGradientRecipe: Codable, Equatable, Sendable {
  public var kind: PaintGradientKind
  public var start: VectorPoint
  public var end: VectorPoint
  public var startColor: LinearRGBAColor
  public var endColor: LinearRGBAColor
  /// The selection at commit time. Nil means the complete canvas.
  public var coverage: MaskRecipe?

  public init(
    kind: PaintGradientKind = .linear,
    start: VectorPoint,
    end: VectorPoint,
    startColor: LinearRGBAColor = .black,
    endColor: LinearRGBAColor = .white,
    coverage: MaskRecipe? = nil
  ) {
    self.kind = kind
    self.start = Self.point(start)
    self.end = Self.point(end)
    self.startColor = startColor
    self.endColor = endColor
    self.coverage = coverage
  }

  private static func point(_ point: VectorPoint) -> VectorPoint {
    VectorPoint(
      x: point.x.isFinite ? min(max(point.x, -16), 16) : 0,
      y: point.y.isFinite ? min(max(point.y, -16), 16) : 0
    )
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      kind: try values.decodeIfPresent(PaintGradientKind.self, forKey: .kind) ?? .linear,
      start: try values.decodeIfPresent(VectorPoint.self, forKey: .start) ?? .zero,
      end: try values.decodeIfPresent(VectorPoint.self, forKey: .end) ?? VectorPoint(x: 1, y: 0),
      startColor: try values.decodeIfPresent(LinearRGBAColor.self, forKey: .startColor) ?? .black,
      endColor: try values.decodeIfPresent(LinearRGBAColor.self, forKey: .endColor) ?? .white,
      coverage: try values.decodeIfPresent(MaskRecipe.self, forKey: .coverage))
  }

  private enum CodingKeys: String, CodingKey {
    case kind, start, end, startColor, endColor, coverage
  }
}

public enum FillSampleSource: String, Codable, CaseIterable, Sendable {
  case composite
  case activeLayer

  public var label: String { self == .composite ? "All Layers" : "Current Layer" }
}

public enum FillRegionMode: String, Codable, CaseIterable, Sendable {
  case selection
  case contiguous

  public var label: String { self == .selection ? "Selection" : "Contiguous" }
}

public struct PaintFillRecipe: Codable, Equatable, Sendable {
  public var color: LinearRGBAColor
  public var coverage: MaskRecipe
  public var source: FillSampleSource
  public var tolerance: Double

  public init(
    color: LinearRGBAColor,
    coverage: MaskRecipe,
    source: FillSampleSource = .composite,
    tolerance: Double = 0.1
  ) {
    self.color = color
    self.coverage = coverage
    self.source = source
    self.tolerance = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0.1
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      color: try values.decodeIfPresent(LinearRGBAColor.self, forKey: .color) ?? .black,
      coverage: try values.decode(MaskRecipe.self, forKey: .coverage),
      source: try values.decodeIfPresent(FillSampleSource.self, forKey: .source) ?? .composite,
      tolerance: try values.decodeIfPresent(Double.self, forKey: .tolerance) ?? 0.1)
  }

  private enum CodingKeys: String, CodingKey { case color, coverage, source, tolerance }
}

public enum ShapeKind: String, Codable, CaseIterable, Sendable {
  case rectangle
  case ellipse
  case line
  case polygon

  public var label: String {
    switch self {
    case .rectangle: "Rectangle"
    case .ellipse: "Ellipse"
    case .line: "Line"
    case .polygon: "Polygon"
    }
  }
}

/// Pure, deterministic flood fill used by the bucket tool and its tests.
public enum ContiguousRegionBuilder {
  public static func mask(
    width: Int,
    height: Int,
    pixels: [LinearRGBAColor],
    seedX: Int,
    seedY: Int,
    tolerance: Double,
    smoothness: Double = 0,
    isCancelled: () -> Bool = { false }
  ) -> RasterMask? {
    guard valid(width: width, height: height, count: pixels.count, seedX: seedX, seedY: seedY)
    else { return nil }
    let threshold = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0.1
    let seed = selectionComparableColor(pixels[seedY * width + seedX])
    func distance(at index: Int) -> Double {
      selectionColorDistance(selectionComparableColor(pixels[index]), seed)
    }
    return build(
      width: width, height: height, seedX: seedX, seedY: seedY,
      matches: { distance(at: $0) <= threshold },
      coverage: { softCoverage(distance: distance(at: $0), tolerance: threshold, smoothness: smoothness) },
      isCancelled: isCancelled
    )
  }

  /// Memory-conscious entry point for Core Image's premultiplied RGBAf output.
  /// It avoids expanding a full-resolution canvas into four `Double` values
  /// per pixel before region discovery.
  public static func mask(
    width: Int,
    height: Int,
    premultipliedRGBA: [Float],
    seedX: Int,
    seedY: Int,
    tolerance: Double,
    smoothness: Double = 0,
    isCancelled: () -> Bool = { false }
  ) -> RasterMask? {
    guard valid(
      width: width, height: height, count: premultipliedRGBA.count / 4,
      seedX: seedX, seedY: seedY),
      premultipliedRGBA.count == width * height * 4
    else { return nil }
    let threshold = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0.1

    func straightColor(at index: Int) -> SelectionComparableColor {
      let offset = index * 4
      let rawAlpha = Double(premultipliedRGBA[offset + 3])
      let alpha = rawAlpha.isFinite ? min(max(rawAlpha, 0), 1) : 1
      func component(_ offset: Int) -> Double {
        guard rawAlpha > 0, rawAlpha.isFinite else { return 0 }
        let value = Double(premultipliedRGBA[offset]) / rawAlpha
        return value.isFinite ? min(max(value, -0.5), 16) : 0
      }
      return selectionComparableColor(
        red: component(offset), green: component(offset + 1),
        blue: component(offset + 2), alpha: alpha)
    }

    let seed = straightColor(at: seedY * width + seedX)
    func distance(at index: Int) -> Double {
      selectionColorDistance(straightColor(at: index), seed)
    }
    return build(
      width: width, height: height, seedX: seedX, seedY: seedY,
      matches: { distance(at: $0) <= threshold },
      coverage: { softCoverage(distance: distance(at: $0), tolerance: threshold, smoothness: smoothness) },
      isCancelled: isCancelled
    )
  }

  private static func valid(
    width: Int, height: Int, count: Int, seedX: Int, seedY: Int
  ) -> Bool {
    width > 0 && height > 0
      && width <= PaintOperationLimits.maximumRasterAxis
      && height <= PaintOperationLimits.maximumRasterAxis
      && width <= PaintOperationLimits.maximumRasterPixels / height
      && count == width * height
      && (0..<width).contains(seedX) && (0..<height).contains(seedY)
  }

  /// Four-connected scanline flood fill. One byte per visited pixel plus a
  /// stack of candidate spans replaces the two whole-canvas Boolean arrays and
  /// per-pixel queue used by a conventional breadth-first implementation.
  private static func build(
    width: Int,
    height: Int,
    seedX: Int,
    seedY: Int,
    matches: (Int) -> Bool,
    coverage: (Int) -> UInt8,
    isCancelled: () -> Bool
  ) -> RasterMask? {
    let seed = seedY * width + seedX
    guard matches(seed) else { return nil }
    var visited = [UInt8](repeating: 0, count: width * height)
    var pending = [seed]
    var runs: [RasterMaskRun] = []

    while let candidate = pending.popLast() {
      guard !isCancelled() else { return nil }
      guard visited[candidate] == 0, matches(candidate) else { continue }
      let y = candidate / width
      let seedColumn = candidate % width
      var left = seedColumn
      while left > 0 {
        let index = y * width + left - 1
        guard visited[index] == 0, matches(index) else { break }
        left -= 1
      }
      var right = seedColumn
      while right + 1 < width {
        let index = y * width + right + 1
        guard visited[index] == 0, matches(index) else { break }
        right += 1
      }
      for x in left...right { visited[y * width + x] = 1 }
      appendCoverageRuns(
        y: y, from: left, through: right, width: width,
        coverage: coverage, to: &runs)
      // Refuse the whole operation instead of serializing a silently clipped
      // connected region when pathological coverage exceeds the file limit.
      guard runs.count <= PaintOperationLimits.maximumRasterRuns else { return nil }

      for adjacentY in [y - 1, y + 1] where (0..<height).contains(adjacentY) {
        var x = left
        while x <= right {
          let index = adjacentY * width + x
          if visited[index] == 0, matches(index) {
            pending.append(index)
            // One candidate represents this adjacent matching span. The span
            // is marked only when popped, preserving ordinary LIFO semantics.
            repeat { x += 1 }
            while x <= right && visited[adjacentY * width + x] == 0
              && matches(adjacentY * width + x)
          } else {
            x += 1
          }
        }
      }
    }

    runs.sort { $0.y == $1.y ? $0.startX < $1.startX : $0.y < $1.y }
    return RasterMask(width: width, height: height, runs: runs)
  }
}

/// Captures every pixel within a sampled color distance, including disconnected
/// regions. Coverage is quantized to 32 levels before run-length encoding: the
/// falloff remains visibly smooth while a photographic selection does not turn
/// one subtly different pixel into one JSON object.
public enum ColorRangeRegionBuilder {
  public static func mask(
    width: Int,
    height: Int,
    premultipliedRGBA: [Float],
    seedX: Int,
    seedY: Int,
    tolerance: Double,
    smoothness: Double,
    isCancelled: () -> Bool = { false }
  ) -> RasterMask? {
    guard width > 0, height > 0,
      width <= PaintOperationLimits.maximumRasterAxis,
      height <= PaintOperationLimits.maximumRasterAxis,
      width <= PaintOperationLimits.maximumRasterPixels / height,
      premultipliedRGBA.count == width * height * 4,
      (0..<width).contains(seedX), (0..<height).contains(seedY)
    else { return nil }

    let threshold = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0.1

    func straightColor(at index: Int) -> SelectionComparableColor {
      let offset = index * 4
      let rawAlpha = Double(premultipliedRGBA[offset + 3])
      let alpha = rawAlpha.isFinite ? min(max(rawAlpha, 0), 1) : 1
      func component(_ componentOffset: Int) -> Double {
        guard rawAlpha > 0, rawAlpha.isFinite else { return 0 }
        let value = Double(premultipliedRGBA[componentOffset]) / rawAlpha
        return value.isFinite ? min(max(value, -0.5), 16) : 0
      }
      return selectionComparableColor(
        red: component(offset), green: component(offset + 1),
        blue: component(offset + 2), alpha: alpha)
    }

    let seed = straightColor(at: seedY * width + seedX)
    func coverage(at index: Int) -> UInt8 {
      let distance = selectionColorDistance(straightColor(at: index), seed)
      return softCoverage(
        distance: distance, tolerance: threshold, smoothness: smoothness)
    }

    var runs: [RasterMaskRun] = []
    for y in 0..<height {
      guard !isCancelled() else { return nil }
      var x = 0
      while x < width {
        let value = coverage(at: y * width + x)
        guard value > 0 else {
          x += 1
          continue
        }
        let start = x
        repeat { x += 1 }
        while x < width && coverage(at: y * width + x) == value
        runs.append(RasterMaskRun(y: y, startX: start, length: x - start, coverage: value))
        guard runs.count <= PaintOperationLimits.maximumRasterRuns else { return nil }
      }
    }
    guard !runs.isEmpty else { return nil }
    return RasterMask(width: width, height: height, runs: runs)
  }
}

/// Expands a painted set of foreground hints while respecting both color
/// similarity and local image edges. The input is deliberately the same
/// bounded RGBAf capture used by the Magnet tool, so Quick Select never needs
/// a full-resolution CPU readback from a large RAW document.
///
/// The returned raster is a capture of the decision, not a live reference to
/// the source pixels. Undo, save/reopen, generation and every other mask
/// consumer therefore see the same selection even after the image changes.
public enum QuickSelectionRegionBuilder {
  public static func mask(
    width: Int,
    height: Int,
    premultipliedRGBA: [Float],
    seedIndices: [Int],
    tolerance: Double,
    edgeSensitivity: Double,
    smoothness: Double,
    isCancelled: () -> Bool = { false }
  ) -> RasterMask? {
    guard width > 0, height > 0,
      width <= PaintOperationLimits.maximumRasterAxis,
      height <= PaintOperationLimits.maximumRasterAxis,
      width <= PaintOperationLimits.maximumRasterPixels / height,
      premultipliedRGBA.count == width * height * 4
    else { return nil }

    let pixelCount = width * height
    let seeds = Array(Set(seedIndices.filter { (0..<pixelCount).contains($0) })).sorted()
    guard !seeds.isEmpty else { return nil }
    let threshold = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0.12
    let edge = edgeSensitivity.isFinite ? min(max(edgeSensitivity, 0), 1) : 0.55
    let edgeLimit = 0.015 + (1 - edge) * 0.35

    func straightColor(at index: Int) -> SelectionComparableColor {
      let offset = index * 4
      let rawAlpha = Double(premultipliedRGBA[offset + 3])
      let alpha = rawAlpha.isFinite ? min(max(rawAlpha, 0), 1) : 1
      func component(_ componentOffset: Int) -> Double {
        guard rawAlpha > 0, rawAlpha.isFinite else { return 0 }
        let value = Double(premultipliedRGBA[componentOffset]) / rawAlpha
        return value.isFinite ? min(max(value, -0.5), 16) : 0
      }
      return selectionComparableColor(
        red: component(offset), green: component(offset + 1),
        blue: component(offset + 2), alpha: alpha)
    }

    // Cache display-referred colors once. Recomputing transfer functions for
    // every palette and neighbor comparison is substantially more work than
    // the bounded proxy itself.
    var colors: [SelectionComparableColor] = []
    colors.reserveCapacity(pixelCount)
    for index in 0..<pixelCount {
      if index & 0x3FFF == 0, isCancelled() { return nil }
      colors.append(straightColor(at: index))
    }

    // A long hint stroke can touch thousands of pixels. A deterministic,
    // evenly-spaced palette preserves its range without making every image
    // pixel compare against every brushed pixel.
    let maximumPaletteCount = 48
    let palette: [SelectionComparableColor]
    if seeds.count <= maximumPaletteCount {
      palette = seeds.map { colors[$0] }
    } else {
      palette = (0..<maximumPaletteCount).map { sample in
        colors[seeds[sample * (seeds.count - 1) / (maximumPaletteCount - 1)]]
      }
    }

    var candidateCoverage = [UInt8](repeating: 0, count: pixelCount)
    for index in 0..<pixelCount {
      if index & 0xFFF == 0, isCancelled() { return nil }
      var distance = Double.greatestFiniteMagnitude
      for reference in palette {
        distance = min(distance, selectionColorDistance(colors[index], reference))
      }
      candidateCoverage[index] = softCoverage(
        distance: distance, tolerance: threshold, smoothness: smoothness)
    }
    // Every painted hint is an explicit foreground assertion, even when the
    // palette was reduced or the source has a sub-pixel edge under the tip.
    for seed in seeds { candidateCoverage[seed] = 255 }

    var reached = [UInt8](repeating: 0, count: pixelCount)
    var pending: [Int] = []
    pending.reserveCapacity(min(pixelCount, seeds.count * 8))
    for seed in seeds where reached[seed] == 0 {
      reached[seed] = 1
      pending.append(seed)
    }
    var cursor = 0
    while cursor < pending.count {
      if cursor & 0xFFF == 0, isCancelled() { return nil }
      let current = pending[cursor]
      cursor += 1
      let x = current % width
      let y = current / width
      for adjacentY in max(0, y - 1)...min(height - 1, y + 1) {
        for adjacentX in max(0, x - 1)...min(width - 1, x + 1) {
          if adjacentX == x, adjacentY == y { continue }
          let adjacent = adjacentY * width + adjacentX
          guard reached[adjacent] == 0, candidateCoverage[adjacent] > 0 else { continue }
          guard selectionColorDistance(colors[current], colors[adjacent]) <= edgeLimit else {
            continue
          }
          reached[adjacent] = 1
          pending.append(adjacent)
        }
      }
    }

    var runs: [RasterMaskRun] = []
    for y in 0..<height {
      if y & 0x3F == 0, isCancelled() { return nil }
      var x = 0
      while x < width {
        let index = y * width + x
        let value = reached[index] == 0 ? 0 : candidateCoverage[index]
        guard value > 0 else {
          x += 1
          continue
        }
        let start = x
        x += 1
        while x < width {
          let next = y * width + x
          guard reached[next] != 0, candidateCoverage[next] == value else { break }
          x += 1
        }
        runs.append(RasterMaskRun(y: y, startX: start, length: x - start, coverage: value))
        guard runs.count <= PaintOperationLimits.maximumRasterRuns else { return nil }
      }
    }
    guard !runs.isEmpty else { return nil }
    return RasterMask(width: width, height: height, runs: runs)
  }
}

/// Color-distance input for click-driven selection. The render pipeline is
/// linear-light, which is correct for compositing but makes a tolerance slider
/// extremely sensitive in shadows. Display P3 uses the sRGB transfer function,
/// so comparing its display-referred components gives dark and bright areas a
/// much more even share of the 0...1 tolerance range. Alpha remains explicit:
/// transparent pixels are not silently treated as opaque pixels of the same
/// nominal RGB color.
private struct SelectionComparableColor {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

private func selectionComparableColor(_ color: LinearRGBAColor) -> SelectionComparableColor {
  selectionComparableColor(
    red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
}

private func selectionComparableColor(
  red: Double, green: Double, blue: Double, alpha: Double
) -> SelectionComparableColor {
  SelectionComparableColor(
    red: displayEncodedSelectionComponent(red),
    green: displayEncodedSelectionComponent(green),
    blue: displayEncodedSelectionComponent(blue),
    alpha: alpha.isFinite ? min(max(alpha, 0), 1) : 1)
}

private func displayEncodedSelectionComponent(_ linear: Double) -> Double {
  let value = linear.isFinite ? min(max(linear, 0), 1) : 0
  if value <= 0.003_130_8 { return 12.92 * value }
  return 1.055 * pow(value, 1 / 2.4) - 0.055
}

private func selectionColorDistance(
  _ color: SelectionComparableColor,
  _ reference: SelectionComparableColor
) -> Double {
  let dr = color.red - reference.red
  let dg = color.green - reference.green
  let db = color.blue - reference.blue
  let da = color.alpha - reference.alpha
  // Four unit-range components, normalized so the opposite corners remain 1.
  return sqrt(dr * dr + dg * dg + db * db + da * da) / 2
}

/// Turns color distance into a compact, soft coverage value. Smoothness zero
/// is a hard boundary. Otherwise the outer `smoothness` fraction of the
/// tolerance fades toward zero, matching the range-mask control's meaning.
private func softCoverage(
  distance: Double,
  tolerance: Double,
  smoothness: Double
) -> UInt8 {
  let threshold = tolerance.isFinite ? min(max(tolerance, 0), 1) : 0.1
  guard distance <= threshold else { return 0 }
  let softness = smoothness.isFinite ? min(max(smoothness, 0), 1) : 0.5
  let falloff = threshold * softness
  let value: Double
  if falloff > 0 {
    value = min(max((threshold - distance) / falloff, 0), 1)
  } else {
    value = 1
  }
  // Thirty-two stable levels keep soft selections compact enough to persist
  // as runs while avoiding visible banding at ordinary canvas zooms.
  let quantized = (value * 31).rounded() / 31
  return UInt8(min(max((quantized * 255).rounded(), 0), 255))
}

private func appendCoverageRuns(
  y: Int,
  from left: Int,
  through right: Int,
  width: Int,
  coverage: (Int) -> UInt8,
  to runs: inout [RasterMaskRun]
) {
  var x = left
  while x <= right {
    let value = coverage(y * width + x)
    guard value > 0 else {
      x += 1
      continue
    }
    let start = x
    repeat { x += 1 }
    while x <= right && coverage(y * width + x) == value
    runs.append(RasterMaskRun(y: y, startX: start, length: x - start, coverage: value))
  }
}

extension VectorPath {
  /// Constructs the first Shape-tool primitives using the Pen tool's existing
  /// path representation, so editing, persistence and export stay shared.
  public static func shape(
    _ kind: ShapeKind,
    from start: VectorPoint,
    to end: VectorPoint,
    polygonSides: Int = 5,
    cornerRadius: Double = 0,
    stroke: VectorStrokeStyle? = VectorStrokeStyle(),
    fill: VectorFillStyle? = nil
  ) -> VectorPath {
    switch kind {
    case .line:
      return VectorPath(name: "Line", anchors: [VectorAnchor(position: start), VectorAnchor(position: end)], stroke: stroke)
    case .rectangle:
      let shape = ShapeMask(from: start, to: end)
      let x0 = shape.origin.x, y0 = shape.origin.y, x1 = shape.maxX, y1 = shape.maxY
      let radius = min(max(cornerRadius, 0), min(shape.width, shape.height) / 2)
      if radius == 0 {
        return VectorPath(name: "Rectangle", anchors: [
          VectorAnchor(position: VectorPoint(x: x0, y: y0)),
          VectorAnchor(position: VectorPoint(x: x1, y: y0)),
          VectorAnchor(position: VectorPoint(x: x1, y: y1)),
          VectorAnchor(position: VectorPoint(x: x0, y: y1)),
        ], isClosed: true, stroke: stroke, fill: fill)
      }
      // Cubic quarter circles. Radius is normalized and deterministic.
      let k = radius * 0.552_284_749_830_793_6
      return VectorPath(name: "Rounded Rectangle", anchors: [
        VectorAnchor(position: VectorPoint(x: x0 + radius, y: y0), incomingHandle: VectorPoint(x: x0 + radius - k, y: y0)),
        VectorAnchor(position: VectorPoint(x: x1 - radius, y: y0), outgoingHandle: VectorPoint(x: x1 - radius + k, y: y0)),
        VectorAnchor(position: VectorPoint(x: x1, y: y0 + radius), incomingHandle: VectorPoint(x: x1, y: y0 + radius - k)),
        VectorAnchor(position: VectorPoint(x: x1, y: y1 - radius), outgoingHandle: VectorPoint(x: x1, y: y1 - radius + k)),
        VectorAnchor(position: VectorPoint(x: x1 - radius, y: y1), incomingHandle: VectorPoint(x: x1 - radius + k, y: y1)),
        VectorAnchor(position: VectorPoint(x: x0 + radius, y: y1), outgoingHandle: VectorPoint(x: x0 + radius - k, y: y1)),
        VectorAnchor(position: VectorPoint(x: x0, y: y1 - radius), incomingHandle: VectorPoint(x: x0, y: y1 - radius + k)),
        VectorAnchor(position: VectorPoint(x: x0, y: y0 + radius), outgoingHandle: VectorPoint(x: x0, y: y0 + radius - k)),
      ], isClosed: true, stroke: stroke, fill: fill)
    case .ellipse:
      let shape = ShapeMask(from: start, to: end)
      let center = shape.center, rx = shape.width / 2, ry = shape.height / 2
      let k = 0.552_284_749_830_793_6
      return VectorPath(name: "Ellipse", anchors: [
        VectorAnchor(position: VectorPoint(x: center.x + rx, y: center.y), incomingHandle: VectorPoint(x: center.x + rx, y: center.y - ry * k), outgoingHandle: VectorPoint(x: center.x + rx, y: center.y + ry * k), kind: .smooth),
        VectorAnchor(position: VectorPoint(x: center.x, y: center.y + ry), incomingHandle: VectorPoint(x: center.x + rx * k, y: center.y + ry), outgoingHandle: VectorPoint(x: center.x - rx * k, y: center.y + ry), kind: .smooth),
        VectorAnchor(position: VectorPoint(x: center.x - rx, y: center.y), incomingHandle: VectorPoint(x: center.x - rx, y: center.y + ry * k), outgoingHandle: VectorPoint(x: center.x - rx, y: center.y - ry * k), kind: .smooth),
        VectorAnchor(position: VectorPoint(x: center.x, y: center.y - ry), incomingHandle: VectorPoint(x: center.x - rx * k, y: center.y - ry), outgoingHandle: VectorPoint(x: center.x + rx * k, y: center.y - ry), kind: .smooth),
      ], isClosed: true, stroke: stroke, fill: fill)
    case .polygon:
      let sides = min(max(polygonSides, PaintOperationLimits.minimumPolygonSides), PaintOperationLimits.maximumPolygonSides)
      let center = VectorPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
      let rx = abs(end.x - start.x) / 2, ry = abs(end.y - start.y) / 2
      let anchors = (0..<sides).map { index -> VectorAnchor in
        let angle = Double.pi / 2 + Double(index) * 2 * Double.pi / Double(sides)
        return VectorAnchor(position: VectorPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry))
      }
      return VectorPath(name: "Polygon", anchors: anchors, isClosed: true, stroke: stroke, fill: fill)
    }
  }
}
