import CoreGraphics
import CoreImage
import Foundation

/// The distribution of the rendered frame, ready to draw.
///
/// ## Which colour space this measures
///
/// The histogram is measured in **display-referred Display P3**: the same
/// primaries as the working space, with the sRGB-like transfer function applied.
/// The working space itself is Extended Linear Display P3, and a linear
/// histogram piles almost everything into the first few bins, which is not what
/// a photographer reads a histogram for. Encoding first gives the familiar
/// photographic shape and puts "clipped" exactly where the display puts it.
///
/// Extended-range values outside 0...1 fold into the end bins, which is the
/// right answer for a display-referred read: they are clipped on this display.
public struct ImageHistogram: Equatable, Sendable {
  public static let binCount = 256

  public var red: [Int]
  public var green: [Int]
  public var blue: [Int]
  /// Rec. 709 luma of the encoded values, the usual photographic luminance
  /// channel. It is computed on the display-referred encoding, not on linear
  /// light, so it matches what the other three channels report.
  public var luminance: [Int]
  public var sampleCount: Int
  /// Pixels with at least one channel at the top of the range.
  public var clippedHighlights: Int
  /// Pixels with every channel at the bottom of the range.
  public var clippedShadows: Int

  public init(
    red: [Int],
    green: [Int],
    blue: [Int],
    luminance: [Int],
    sampleCount: Int,
    clippedHighlights: Int,
    clippedShadows: Int
  ) {
    self.red = red
    self.green = green
    self.blue = blue
    self.luminance = luminance
    self.sampleCount = sampleCount
    self.clippedHighlights = clippedHighlights
    self.clippedShadows = clippedShadows
  }

  /// The tallest bin in any channel, which is what the drawing scales against.
  public var peak: Int {
    max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0, luminance.max() ?? 0)
  }

  /// The bin height the plot should treat as full scale.
  ///
  /// The two end bins are excluded: clipped pixels pile into them, and a large
  /// clipped area would otherwise scale the entire plot down to a flat line and
  /// hide the shape of the image. Anything above this ceiling is drawn
  /// flattened against the top edge, and the clipping indicators — not the plot
  /// height — are what report how much is clipped.
  public var displayCeiling: Int {
    let interior = { (bins: [Int]) -> Int in
      guard bins.count > 2 else { return bins.max() ?? 0 }
      return bins[1..<(bins.count - 1)].max() ?? 0
    }
    let ceiling = max(
      interior(red), interior(green), interior(blue), interior(luminance))
    return ceiling > 0 ? ceiling : max(peak, 1)
  }

  public var highlightFraction: Double {
    sampleCount > 0 ? Double(clippedHighlights) / Double(sampleCount) : 0
  }

  public var shadowFraction: Double {
    sampleCount > 0 ? Double(clippedShadows) / Double(sampleCount) : 0
  }

  /// Counts one display-referred RGBA8 buffer, as Core Image hands it back:
  /// premultiplied, one byte per channel, `width * 4` bytes per row.
  ///
  /// Fully transparent pixels are skipped: a canvas document is transparent
  /// outside its content, and counting that as clipped black would drown the
  /// shadow end.
  public static func counting(
    displayReferredRGBA8 bytes: [UInt8],
    width: Int,
    height: Int
  ) -> ImageHistogram {
    var red = [Int](repeating: 0, count: binCount)
    var green = red
    var blue = red
    var luminance = red
    var sampleCount = 0
    var clippedHighlights = 0
    var clippedShadows = 0

    let rowBytes = width * 4
    guard width > 0, height > 0, bytes.count >= rowBytes * height else {
      return ImageHistogram(
        red: red, green: green, blue: blue, luminance: luminance,
        sampleCount: 0, clippedHighlights: 0, clippedShadows: 0)
    }

    let readback = DecimatedReadback(bytes: bytes, width: width, height: height)
    for row in 0..<height {
      let start = row * rowBytes
      for column in 0..<width {
        let offset = start + column * 4
        guard let (r, g, b) = readback.straightPixel(atByteOffset: offset) else { continue }
        red[r] += 1
        green[g] += 1
        blue[b] += 1
        let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        luminance[min(Int(luma.rounded()), binCount - 1)] += 1
        sampleCount += 1
        if r == 255 || g == 255 || b == 255 { clippedHighlights += 1 }
        if r == 0 && g == 0 && b == 0 { clippedShadows += 1 }
      }
    }

    return ImageHistogram(
      red: red,
      green: green,
      blue: blue,
      luminance: luminance,
      sampleCount: sampleCount,
      clippedHighlights: clippedHighlights,
      clippedShadows: clippedShadows
    )
  }

  /// Measures an image through `context`, on whatever actor owns that context.
  ///
  /// See `DecimatedReadback` for why the image is decimated rather than
  /// averaged before it is read back.
  static func measure(
    _ image: CIImage,
    context: CIContext,
    displayColorSpace: CGColorSpace,
    maximumSampleEdge: Int
  ) -> ImageHistogram? {
    guard
      let readback = DecimatedReadback.read(
        image,
        context: context,
        displayColorSpace: displayColorSpace,
        maximumSampleEdge: maximumSampleEdge
      )
    else { return nil }
    return counting(
      displayReferredRGBA8: readback.bytes, width: readback.width, height: readback.height)
  }
}
