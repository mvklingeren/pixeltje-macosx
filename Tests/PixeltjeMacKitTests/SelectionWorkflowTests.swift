import CoreImage
import Foundation
import ImageIO
import PixeltjeMacDomain
import Testing
import UniformTypeIdentifiers

@testable import PixeltjeMacKit

@Test func selectionWorkflowPlacesNativeMaskWithinTheSelectedCanvasRegion() throws {
  // Readback rows are in canonical bottom-left order. Two disjoint white
  // regions prove that row orientation and run boundaries survive conversion.
  let white: [UInt8] = [255, 255, 255, 255]
  let black: [UInt8] = [0, 0, 0, 255]
  let rgba = black + white + white + black
    + white + black + black + black
  let selection = try SelectionWorkflowSupport.mask(
    rgba: rgba,
    width: 4,
    height: 2,
    placement: LayerFrame(x: 100, y: 50, width: 400, height: 200),
    canvas: CanvasRecipe(width: 1000, height: 500),
    prompt: "clock")
  guard case .placedRaster(let placed) = selection.components.first?.generator else {
    Issue.record("Expected a placed raster selection")
    return
  }
  #expect(placed.raster.runs == [
    RasterMaskRun(y: 0, startX: 1, length: 2),
    RasterMaskRun(y: 1, startX: 0, length: 1),
  ])
  #expect(placed.frame.origin == VectorPoint(x: 0.1, y: 0.1))
  #expect(placed.frame.width == 0.4)
  #expect(placed.frame.height == 0.4)
  let outline = try #require(SelectionGeometry.path(
    for: selection, in: CGRect(x: 0, y: 0, width: 1000, height: 500)))
  #expect(abs(outline.boundingBox.minX - 100) < 0.01)
  #expect(abs(outline.boundingBox.minY - 50) < 0.01)
  #expect(abs(outline.boundingBox.maxX - 400) < 0.01)
  #expect(abs(outline.boundingBox.maxY - 250) < 0.01)
  let restored = try JSONDecoder().decode(
    MaskRecipe.self, from: JSONEncoder().encode(selection))
  #expect(restored == selection)
}

@Test func selectionWorkflowRejectsAnEmptyReturnedMask() {
  #expect(throws: (any Error).self) {
    try SelectionWorkflowSupport.mask(
      rgba: [UInt8](repeating: 0, count: 4 * 4 * 4),
      width: 4,
      height: 4,
      placement: LayerFrame(x: 0, y: 0, width: 100, height: 100),
      canvas: CanvasRecipe(width: 100, height: 100),
      prompt: "clock")
  }
}

@MainActor
@Test func placedSelectionRendersAtItsCanvasPositionAndSurvivesCanvasResize() throws {
  let white: [UInt8] = [255, 255, 255, 255]
  let black: [UInt8] = [0, 0, 0, 255]
  let selection = try SelectionWorkflowSupport.mask(
    rgba: black + white + white + black + white + black + black + black,
    width: 4,
    height: 2,
    placement: LayerFrame(x: 10, y: 5, width: 20, height: 10),
    canvas: CanvasRecipe(width: 40, height: 20),
    prompt: "clock")
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
  let context = CIContext(options: [.workingColorSpace: colorSpace])
  let renderer = MaskRenderer(context: context, workingColorSpace: colorSpace)
  let coverageImage = try #require(try renderer.evaluate(
    selection,
    in: MaskSpace(
      extent: CGRect(x: 0, y: 0, width: 40, height: 20),
      pixelsPerCanvasPixel: 1),
    source: nil,
    sourceIdentity: "placed-selection-test"))
  let image = renderer.maskImage(from: coverageImage)
  func coverage(x: Int, y: Int) -> Float {
    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      image,
      toBitmap: &pixel,
      rowBytes: 4 * MemoryLayout<Float>.size,
      bounds: CGRect(x: x, y: y, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: nil)
    #expect(abs(pixel[3] - 1) < 0.01)
    return pixel[0]
  }
  #expect(coverage(x: 17, y: 7) > 0.99)
  #expect(coverage(x: 22, y: 7) > 0.99)
  #expect(coverage(x: 12, y: 12) > 0.99)
  #expect(coverage(x: 12, y: 7) < 0.01)
  #expect(coverage(x: 17, y: 12) < 0.01)
  #expect(coverage(x: 35, y: 12) < 0.01)

  guard case .placedRaster(let original) = selection.components.first?.generator else {
    Issue.record("Expected the original placed raster")
    return
  }
  let moved = selection.resizingCanvas(
    from: CanvasRecipe(width: 40, height: 20),
    to: CanvasRecipe(width: 50, height: 30),
    offset: CanvasOffset(x: 5, y: 5))
  guard case .placedRaster(let placed) = moved.components.first?.generator else {
    Issue.record("Expected a placed raster after canvas resize")
    return
  }
  #expect(abs(placed.frame.origin.x - 0.3) < 0.0001)
  #expect(abs(placed.frame.origin.y - (10.0 / 30.0)) < 0.0001)
  #expect(abs(placed.frame.width - 0.4) < 0.0001)
  #expect(abs(placed.frame.height - (10.0 / 30.0)) < 0.0001)
  #expect(placed.raster == original.raster)
}

@Test func selectionWorkflowImportsAComfyMaskPNGAtTheCapturedPlacement() throws {
  let black: [UInt8] = [0, 0, 0, 255]
  let white: [UInt8] = [255, 255, 255, 255]
  let pixels = black + white + black + black
    + black + black + white + black
  let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
  let cgImage = try #require(CGImage(
    width: 4, height: 2,
    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
    space: sRGB,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent))
  let encoded = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(
    encoded, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, cgImage, nil)
  #expect(CGImageDestinationFinalize(destination))
  let png = encoded as Data
  let selection = try SelectionWorkflowSupport.mask(
    imageData: png,
    width: 4,
    height: 2,
    placement: LayerFrame(x: 100, y: 50, width: 400, height: 200),
    canvas: CanvasRecipe(width: 1000, height: 500),
    prompt: "clock")
  guard case .placedRaster(let placed) = selection.components.first?.generator else {
    Issue.record("Expected a placed raster selection")
    return
  }
  #expect(placed.raster.runs == [
    RasterMaskRun(y: 0, startX: 2, length: 1),
    RasterMaskRun(y: 1, startX: 1, length: 1),
  ])
}
