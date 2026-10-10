import CoreGraphics
import CoreImage
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

private let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

private func colorPixel(_ image: CIImage) -> [Float] {
  var pixel = [Float](repeating: 0, count: 4)
  CIContext(options: [.workingColorSpace: linearP3]).render(
    image,
    toBitmap: &pixel,
    rowBytes: MemoryLayout<Float>.size * 4,
    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
    format: .RGBAf,
    colorSpace: linearP3)
  return pixel
}

private func solid(_ red: Double, _ green: Double, _ blue: Double) -> CIImage {
  var values = [Float(red), Float(green), Float(blue), 1]
  let data = values.withUnsafeMutableBufferPointer { Data(buffer: $0) }
  return CIImage(
    bitmapData: data,
    bytesPerRow: MemoryLayout<Float>.size * 4,
    size: CGSize(width: 1, height: 1),
    format: .RGBAf,
    colorSpace: linearP3)
}

@Test func neutralColorRecipesAreExactGraphNoOps() {
  let image = solid(0.8, 0.3, 0.1)
  #expect(LayerAdjustmentGraph.applyColorMixer(.neutral, to: image) == image)
  #expect(LayerAdjustmentGraph.applyColorGrading(.neutral, to: image) == image)
  #expect(LayerAdjustmentGraph.apply(.curves(.neutral), to: image) == image)
  #expect(LayerAdjustmentGraph.apply(.levels(.neutral), to: image) == image)
  #expect(LayerAdjustmentGraph.apply(.hueSaturation(.neutral), to: image) == image)
  #expect(LayerAdjustmentGraph.apply(.blackAndWhite(.neutral), to: image) == image)
  #expect(LayerAdjustmentGraph.apply(.colorLookup(.neutral), to: image) == image)
  #expect(LayerAdjustmentGraph.apply(.gradientMap(.neutral), to: image) == image)
}

@Test func colorMixerSelectsChromaticBandsWithoutMovingGray() {
  var mixer = ColorMixerRecipe()
  mixer[.red].luminance = -100

  let redBefore = colorPixel(solid(0.8, 0.05, 0.04))
  let redAfter = colorPixel(
    LayerAdjustmentGraph.applyColorMixer(mixer, to: solid(0.8, 0.05, 0.04)))
  #expect(redAfter[0] < redBefore[0] * 0.7)

  let grayBefore = colorPixel(solid(0.4, 0.4, 0.4))
  let grayAfter = colorPixel(
    LayerAdjustmentGraph.applyColorMixer(mixer, to: solid(0.4, 0.4, 0.4)))
  for channel in 0..<3 {
    #expect(abs(grayAfter[channel] - grayBefore[channel]) < 0.0001)
  }
}

@Test func linearColorGradingKeepsExtendedRangeInsteadOfClippingAtOne() {
  var grading = ColorGradingRecipe()
  grading.highlights = ColorGradingWheel(hue: 0, saturation: 50, luminance: 0)
  let output = colorPixel(
    LayerAdjustmentGraph.applyColorGrading(grading, to: solid(2, 1, 0.5)))

  #expect(output[0] > 2)
  #expect(output[0] > 1)
  #expect(output.allSatisfy { $0.isFinite })
}

@Test func everyStrongerAdjustmentLayerProducesDeterministicFinitePixels() {
  var curve = ToneCurveRecipe.neutral
  curve.rgb = PointToneCurve(points: [
    ToneCurvePoint(x: 0, y: 0.05), ToneCurvePoint(x: 0.5, y: 0.65),
    ToneCurvePoint(x: 1, y: 1),
  ])
  let recipes: [AdjustmentRecipe] = [
    .curves(curve),
    .levels(LevelsAdjustment(blackPoint: 0.05, whitePoint: 0.9, gamma: 1.2)),
    .hueSaturation(HueSaturationAdjustment(hue: 30, saturation: 20, lightness: 5)),
    .blackAndWhite(BlackAndWhiteAdjustment(amount: 1)),
    .colorLookup(ColorLookupAdjustment(style: .cinematic, amount: 1)),
    .gradientMap(GradientMapAdjustment(style: .blueOrange, amount: 1)),
  ]
  let input = solid(0.72, 0.31, 0.12)
  let original = colorPixel(input)

  for recipe in recipes {
    let first = colorPixel(LayerAdjustmentGraph.apply(recipe, to: input))
    let second = colorPixel(LayerAdjustmentGraph.apply(recipe, to: input))
    #expect(zip(first, second).allSatisfy { abs($0 - $1) < 0.000001 })
    #expect(first.allSatisfy { $0.isFinite })
    #expect(first != original)
  }
}
