import CoreGraphics
import CoreImage
import Foundation

/// One entry in a palette, in display-referred Display P3.
///
/// The same space the histogram is measured in, and for the same reason: it is
/// what the canvas shows. A palette quantized in the linear working space would
/// crowd almost every entry into the shadows, because that is where linear
/// light puts most of an image's numeric range.
public struct PaletteColor: Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }


  /// Rec. 709 luma of the encoded values, which is what the entries are ordered
  /// by. Computed on the display-referred encoding, like the histogram's.
  public var luminance: Double {
    0.2126 * red + 0.7152 * green + 0.0722 * blue
  }

  /// The swatch's name in the color panel, and the key that makes it unique in
  /// a color list. A hex triplet is the one name that is both.
  public var hexName: String {
    let channel = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
  }
}

/// The colors a rendered frame is actually made of.
///
/// Not the most common pixels, which in a photograph are a few hundred
/// near-identical shades of one subject, and not an even slice of the color
/// cube, which is mostly colors the image does not contain. The frame is
/// bucketed coarsely, the buckets are ranked by how much of the image they
/// cover, and a bucket is only accepted if it is far enough from everything
/// accepted before it. That gives the dominant colors, each one distinct enough
/// from its neighbours to be worth its own swatch.
enum SampledPalette {
  /// How many entries a sampled palette carries at most. Two rows of twelve in
  /// the color panel's swatch grid.
  static let limit = 24

  /// Bits dropped from each channel when bucketing. Five significant bits give
  /// 32³ buckets, fine enough to keep two nearby skin tones apart and coarse
  /// enough that sensor noise lands in one bucket rather than a hundred.
  static let droppedBits = 3

  /// How far apart two accepted entries must be, as a distance in 0...255 RGB.
  /// Below this the second swatch reads as a duplicate of the first.
  static let separation = 40.0

  /// The long edge the frame is decimated to before sampling. The palette is a
  /// statistical read, so this is small enough to be nearly free and still
  /// carry every region of the image.
  static let maximumSampleEdge = 160

  /// Ranks the colors of a display-referred RGBA8 buffer.
  ///
  /// Fully transparent pixels are skipped: the area outside a canvas
  /// document's content is not a color the document contains.
  static func ranking(
    displayReferredRGBA8 bytes: [UInt8],
    width: Int,
    height: Int,
    limit: Int = limit,
    separation: Double = separation
  ) -> [PaletteColor] {
    let rowBytes = width * 4
    guard width > 0, height > 0, limit > 0, bytes.count >= rowBytes * height else { return [] }

    struct Bucket {
      var count = 0
      var red = 0
      var green = 0
      var blue = 0
    }

    let readback = DecimatedReadback(bytes: bytes, width: width, height: height)
    var buckets: [Int: Bucket] = [:]
    for row in 0..<height {
      let start = row * rowBytes
      for column in 0..<width {
        guard let pixel = readback.straightPixel(atByteOffset: start + column * 4) else { continue }
        let key =
          (pixel.red >> droppedBits) << (2 * (8 - droppedBits))
          | (pixel.green >> droppedBits) << (8 - droppedBits)
          | (pixel.blue >> droppedBits)
        var bucket = buckets[key] ?? Bucket()
        bucket.count += 1
        bucket.red += pixel.red
        bucket.green += pixel.green
        bucket.blue += pixel.blue
        buckets[key] = bucket
      }
    }

    // Coverage decides the order, and the bucket key breaks ties, so the same
    // frame always produces the same palette rather than one that reshuffles
    // itself on every render.
    let ranked = buckets.sorted { left, right in
      left.value.count == right.value.count
        ? left.key < right.key : left.value.count > right.value.count
    }

    var accepted: [(red: Double, green: Double, blue: Double)] = []
    let squaredSeparation = separation * separation
    for (_, bucket) in ranked {
      guard accepted.count < limit else { break }
      let mean = (
        red: Double(bucket.red) / Double(bucket.count),
        green: Double(bucket.green) / Double(bucket.count),
        blue: Double(bucket.blue) / Double(bucket.count)
      )
      let isDistinct = accepted.allSatisfy { existing in
        let dr = existing.red - mean.red
        let dg = existing.green - mean.green
        let db = existing.blue - mean.blue
        return dr * dr + dg * dg + db * db >= squaredSeparation
      }
      if isDistinct { accepted.append(mean) }
    }

    // Ordered light to dark for display. Rank decided which colors are in the
    // palette; it is a poor order to read a row of swatches in.
    return
      accepted
      .map { PaletteColor(red: $0.red / 255, green: $0.green / 255, blue: $0.blue / 255) }
      .sorted { $0.luminance < $1.luminance }
  }

  /// Samples an image through `context`, on whatever actor owns that context.
  static func sample(
    _ image: CIImage,
    context: CIContext,
    displayColorSpace: CGColorSpace,
    maximumSampleEdge: Int = maximumSampleEdge,
    limit: Int = limit
  ) -> [PaletteColor] {
    guard
      let readback = DecimatedReadback.read(
        image,
        context: context,
        displayColorSpace: displayColorSpace,
        maximumSampleEdge: maximumSampleEdge
      )
    else { return [] }
    return ranking(
      displayReferredRGBA8: readback.bytes,
      width: readback.width,
      height: readback.height,
      limit: limit
    )
  }
}
