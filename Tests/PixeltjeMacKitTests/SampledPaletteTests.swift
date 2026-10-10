import AppKit
import Foundation
import Testing

@testable import PixeltjeMacKit

/// Builds a display-referred, premultiplied RGBA8 buffer from straight colors,
/// which is the shape both the histogram and the palette read.
private func buffer(_ pixels: [(r: Int, g: Int, b: Int, a: Int)]) -> [UInt8] {
  pixels.flatMap { pixel -> [UInt8] in
    let premultiply = { (value: Int) in
      UInt8(min(Int((Double(value) * Double(pixel.a) / 255).rounded()), 255))
    }
    return [premultiply(pixel.r), premultiply(pixel.g), premultiply(pixel.b), UInt8(pixel.a)]
  }
}

@Test func theSampledPaletteRanksByCoverageAndReturnsItLightToDark() {
  // Three flat colors in a 4×1 strip: red twice, then green, then white.
  let bytes = buffer([(220, 20, 20, 255), (220, 20, 20, 255), (20, 200, 20, 255), (250, 250, 250, 255)])
  let palette = SampledPalette.ranking(displayReferredRGBA8: bytes, width: 4, height: 1)

  #expect(palette.map(\.hexName) == ["#DC1414", "#14C814", "#FAFAFA"])
  #expect(palette.map(\.luminance) == palette.map(\.luminance).sorted())
}

@Test func aColorTooCloseToOneAlreadyTakenDoesNotEarnItsOwnSwatch() {
  // The second red is four steps from the first, far below the separation.
  let close = buffer([(200, 40, 40, 255), (204, 44, 44, 255), (40, 40, 200, 255)])
  #expect(SampledPalette.ranking(displayReferredRGBA8: close, width: 3, height: 1).count == 2)

  // Widen them past the separation and both are worth showing.
  let apart = buffer([(200, 40, 40, 255), (140, 40, 40, 255), (40, 40, 200, 255)])
  #expect(SampledPalette.ranking(displayReferredRGBA8: apart, width: 3, height: 1).count == 3)
}

/// The area outside a canvas document's content is not a color the document
/// contains, and a half-transparent pixel is not the midtone its premultiplied
/// bytes look like.
@Test func transparentPixelsAreSkippedAndPartialOnesAreUnpremultiplied() {
  let bytes = buffer([(255, 255, 255, 0), (200, 100, 50, 128)])
  let palette = SampledPalette.ranking(displayReferredRGBA8: bytes, width: 2, height: 1)

  #expect(palette.count == 1)
  // Within a rounding step of the straight color, not of its premultiplied half.
  let color = try? #require(palette.first)
  #expect(abs((color?.red ?? 0) * 255 - 200) <= 1)
  #expect(abs((color?.green ?? 0) * 255 - 100) <= 1)
  #expect(abs((color?.blue ?? 0) * 255 - 50) <= 1)
}

@Test func theSampledPaletteIsCappedAndNeverExceedsTheLimit() {
  // A full sweep of hues, far more distinct colors than the cap allows.
  let pixels = (0..<256).map { step -> (r: Int, g: Int, b: Int, a: Int) in
    let color = PaletteColor(hue: Double(step) / 256, saturation: 1, brightness: 1)
    return (Int(color.red * 255), Int(color.green * 255), Int(color.blue * 255), 255)
  }
  let palette = SampledPalette.ranking(displayReferredRGBA8: buffer(pixels), width: 256, height: 1)
  #expect(palette.count == SampledPalette.limit)
}

@Test func anEmptyOrFullyTransparentFrameProducesNoPalette() {
  #expect(SampledPalette.ranking(displayReferredRGBA8: [], width: 0, height: 0).isEmpty)
  let clear = buffer([(255, 255, 255, 0), (0, 0, 0, 0)])
  #expect(SampledPalette.ranking(displayReferredRGBA8: clear, width: 2, height: 1).isEmpty)
}

/// Hue, saturation and brightness are converted in this file so the numbers are
/// Display P3 coordinates exactly as written, rather than the calibrated-space
/// ones `NSColor(hue:saturation:brightness:)` would give.
@Test func theDefaultPaletteCoversNeutralsAndHuesWithoutRepeatingASwatch() {
  let colors = ColorPanelPalette.defaultColors

  #expect(PaletteColor(hue: 0, saturation: 1, brightness: 1).hexName == "#FF0000")
  #expect(PaletteColor(hue: 1.0 / 3, saturation: 1, brightness: 1).hexName == "#00FF00")
  #expect(PaletteColor(hue: 2.0 / 3, saturation: 1, brightness: 1).hexName == "#0000FF")
  #expect(PaletteColor(hue: 0.5, saturation: 0, brightness: 0.5).hexName == "#808080")

  #expect(colors.contains(PaletteColor(red: 0, green: 0, blue: 0)))
  #expect(colors.contains(PaletteColor(red: 1, green: 1, blue: 1)))
  // A color list is keyed by name, so a repeat would silently drop a swatch.
  #expect(Set(colors.map(\.hexName)).count == colors.count)
}
