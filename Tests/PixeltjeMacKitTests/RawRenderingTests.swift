import CoreImage
import Foundation
import Metal
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

// A caller supplies a legally available local RAW; it is never copied or modified.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELTJE_TEST_RAW"] != nil))
func cachedRawEditsPreservePixelsAndAvoidRedecode() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["PIXELTJE_TEST_RAW"])
  let engine = try RenderEngine(observesMemoryPressure: false)
  let url = URL(fileURLWithPath: path)
  let source = SourceReference(
    originalFilename: url.lastPathComponent, linkedPath: path,
    securityScopedBookmark: nil, fingerprint: .init(byteLength: 0, modificationDate: nil))
  var request = RenderRequest(
    documentID: UUID(), revision: 1, input: .file(url),
    recipe: ProjectRecipe(source: source), quality: .proxy(maximumLongEdge: 2048))
  let original = try await engine.render(request)
  let originalPixels = pixels(original)
  print("RAW baseline: \(original.width)x\(original.height), \(original.elapsedSeconds)s")
  // A RAW render always reports what the decoder found; only a document without
  // a RAW source renders without an inspection.
  let inspection = try #require(original.inspection)
  var rawDevelopment = try #require(
    request.recipe.layerStack.layer(id: .rawBackground)?.developedRawLayer?.rawDevelopment
  )
  rawDevelopment.parameters = inspection.defaults
  rawDevelopment.decoderVersion = inspection.selectedDecoderVersion
  request.recipe.layerStack = request.recipe.layerStack.settingRawDevelopment(
    rawDevelopment,
    for: .rawBackground
  )
  request.recipe.rawDevelopment = rawDevelopment
  let duplicateID = ProjectLayerID()
  request.recipe.layerStack = request.recipe.layerStack.duplicating(
    .rawBackground, as: duplicateID)
  let duplicate = try await engine.render(request)
  #expect(pixels(duplicate) == originalPixels)
  #expect(await engine.rawSessionCount == 2)
  #expect(await engine.rawDevelopmentCount == 2)
  print("Duplicate RAW layers: \(duplicate.elapsedSeconds)s, exact pixel match")

  // The legacy document-wide color controls affect only the original
  // background RAW, so hide the independent duplicate before exercising them.
  request.recipe.layerStack = request.recipe.layerStack.settingEnabled(false, for: duplicateID)
  request.recipe.postProcessing.saturation = 0.5
  let desaturated = try await engine.render(request)
  #expect(pixels(desaturated) != originalPixels)
  #expect(await engine.rawDevelopmentCount == 2)
  request.recipe.postProcessing = PostProcessingRecipe()
  rawDevelopment.parameters?.exposure += 0.5
  request.recipe.layerStack = request.recipe.layerStack.settingRawDevelopment(
    rawDevelopment,
    for: .rawBackground
  )
  request.recipe.rawDevelopment = rawDevelopment
  let adjusted = try await engine.render(request)
  #expect(pixels(adjusted) != originalPixels)
  #expect(await engine.rawSessionCount == 2)
  #expect(await engine.rawDevelopmentCount == 3)
  print("Warm exposure edit: \(adjusted.elapsedSeconds)s")

  // Reset must match a fresh render, including color, after mutating the filter.
  rawDevelopment.parameters = inspection.defaults
  request.recipe.layerStack = request.recipe.layerStack.settingRawDevelopment(
    rawDevelopment,
    for: .rawBackground
  )
  request.recipe.rawDevelopment = rawDevelopment
  let reset = try await engine.render(request)
  #expect(reset.width == original.width && reset.height == original.height)
  let resetPixels = pixels(reset)
  let error = zip(resetPixels, originalPixels).map { abs($0 - $1) }.max() ?? 0
  print(
    "Reset mean absolute error: \(zip(resetPixels, originalPixels).map { abs($0 - $1) }.reduce(0,+) / Float(resetPixels.count))"
  )
  #expect(error <= 0.002)
  print("Reset vs original max RGBA error: \(error)")
  await engine.clearCaches()
  let fresh = try await engine.render(request)
  let freshError = zip(pixels(fresh), resetPixels).map { abs($0 - $1) }.max() ?? 0
  #expect(freshError <= 0.002)
  #expect(await engine.rawSessionCount == 3)

  // Real full-resolution rendering remains separate from the draft session.
  if ProcessInfo.processInfo.environment["PIXELTJE_TEST_FULL"] == "1" {
    request.quality = .full
    let full = try await engine.render(request)
    let fullPixels = pixels(full)
    #expect(await engine.rawSessionCount == 4)
    #expect(await engine.hasCachedFullResolution(request))
    let developments = await engine.rawDevelopmentCount
    request.recipe.layerStack = request.recipe.layerStack.settingEnabled(true, for: duplicateID)
      .settingEnabled(false, for: .rawBackground)
    let fullDuplicate = try await engine.render(request)
    #expect(pixels(fullDuplicate) == fullPixels)
    #expect(await engine.rawDevelopmentCount == developments + 1)
    #expect(await engine.rawSessionCount == 5)
    print("Full RAW: \(full.elapsedSeconds)s; cached layer: \(fullDuplicate.elapsedSeconds)s")
  }
}

private func pixels(_ frame: RenderedFrame) -> [Float] {
  let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  let context = CIContext(options: [.workingColorSpace: space])
  let image = CIImage(ioSurface: frame.surface, options: [.colorSpace: space])
  // Read a grid of the complete, already-materialized result, never a RAW ROI.
  let sample = image.transformed(
    by: .init(scaleX: 64 / CGFloat(frame.width), y: 64 / CGFloat(frame.height)))
  var values = [Float](repeating: 0, count: 64 * 64 * 4)
  context.render(
    sample, toBitmap: &values, rowBytes: 64 * 4 * 4,
    bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: space)
  return values
}
