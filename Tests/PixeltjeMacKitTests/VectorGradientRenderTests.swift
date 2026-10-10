import CoreGraphics
import Foundation
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

/// A closed square covering the whole canvas, filled with `fill`.
private func filledCanvasLayer(_ fill: VectorFillStyle) -> ProjectLayer {
  let path = VectorPath(
    name: "Filled",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 0)),
      VectorAnchor(position: VectorPoint(x: 1, y: 1)),
      VectorAnchor(position: VectorPoint(x: 0, y: 1)),
    ],
    isClosed: true,
    stroke: nil,
    fill: fill
  )
  return ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(path)]))
  )
}

/// Samples the rendered artwork as 8-bit sRGB, which is all these assertions
/// need: the float surface is verified elsewhere.
func sampled(
  _ layer: ProjectLayer, width: Int, height: Int
) throws -> (pixels: [UInt8], bytesPerRow: Int) {
  let raw = ProjectLayer.rawBase()
  let stack = LayerStack(layers: [raw, layer], activeLayerID: layer.id)
  let workingSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
  let artwork = try #require(
    try VectorArtworkRenderer.makeCGImage(
      layerStack: stack, width: width, height: height, workingColorSpace: workingSpace))

  let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let bytesPerRow = width * 4
  try pixels.withUnsafeMutableBytes { buffer in
    let context = try #require(
      CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return (pixels, bytesPerRow)
}

@Test func regionalVectorRenderingAllocatesOnlyTheRequestedPixels() throws {
  let layer = filledCanvasLayer(VectorFillStyle(color: .white))
  let stack = LayerStack(
    layers: [ProjectLayer.rawBase(), layer], activeLayerID: layer.id)
  let workingSpace = try #require(
    CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
  let region = CGRect(x: 123, y: 77, width: 11, height: 7)
  let image = try #require(
    try VectorArtworkRenderer.makeCGImage(
      layerStack: stack,
      width: 4_000,
      height: 3_000,
      workingColorSpace: workingSpace,
      region: region))

  #expect(image.width == 11)
  #expect(image.height == 7)
}

@Test func aLinearGradientFillRampsAcrossTheObjectItFills() throws {
  let gradient = VectorGradient(
    stops: [
      VectorGradientStop(color: .black, position: 0),
      VectorGradientStop(color: .white, position: 1),
    ],
    start: VectorPoint(x: 0, y: 0.5),
    end: VectorPoint(x: 1, y: 0.5)
  )
  let sample = try sampled(
    filledCanvasLayer(VectorFillStyle(gradient: gradient)), width: 64, height: 8)

  // Row 4, reading red across the ramp.
  let row = 4 * sample.bytesPerRow
  let left = sample.pixels[row + 2 * 4]
  let middle = sample.pixels[row + 32 * 4]
  let right = sample.pixels[row + 61 * 4]
  #expect(left < middle)
  #expect(middle < right)
  // The blend happens in the linear working space, so the encoded values are
  // not the midpoints an sRGB-space ramp would give: a linear 4% is already a
  // visible dark grey once encoded. That is the intended behavior, not drift.
  #expect(left < 80)
  #expect(right > 215)

  // Every step across the ramp moves, which is what an un-banded gradient at
  // this width looks like: an 8-bit intermediate would repeat values.
  var increases = 0
  for column in 1..<64 {
    let previous = sample.pixels[row + (column - 1) * 4]
    let current = sample.pixels[row + column * 4]
    if current > previous { increases += 1 }
  }
  #expect(increases > 50)
}

@Test func addingAStopDoesNotChangeTheLinearLightRamp() throws {
  let original = VectorGradient(
    stops: [
      VectorGradientStop(color: .black, position: 0),
      VectorGradientStop(color: .white, position: 1),
    ],
    start: VectorPoint(x: 0, y: 0.5),
    end: VectorPoint(x: 1, y: 0.5))
  let inserted = original.addingStop(at: 0.5)

  let before = try sampled(
    filledCanvasLayer(VectorFillStyle(gradient: original)), width: 128, height: 4)
  let after = try sampled(
    filledCanvasLayer(VectorFillStyle(gradient: inserted)), width: 128, height: 4)
  #expect(before.pixels == after.pixels)
}

@Test func aCustomMidpointIsEvaluatedInLinearLight() throws {
  let centered = VectorGradient(
    stops: [
      VectorGradientStop(color: .black, position: 0),
      VectorGradientStop(color: .white, position: 1),
    ],
    start: VectorPoint(x: 0, y: 0.5),
    end: VectorPoint(x: 1, y: 0.5))
  let early = VectorGradient(
    stops: [
      VectorGradientStop(color: .black, position: 0, midpoint: 0.25),
      VectorGradientStop(color: .white, position: 1),
    ],
    start: VectorPoint(x: 0, y: 0.5),
    end: VectorPoint(x: 1, y: 0.5))
  let centeredSample = try sampled(
    filledCanvasLayer(VectorFillStyle(gradient: centered)), width: 256, height: 4)
  let earlySample = try sampled(
    filledCanvasLayer(VectorFillStyle(gradient: early)), width: 256, height: 4)
  let row = 2 * centeredSample.bytesPerRow
  let centeredHalf = centeredSample.pixels[row + 128 * 4]
  let earlyQuarter = earlySample.pixels[row + 64 * 4]

  // Both positions describe 50% linear light. Quantization and the midpoint's
  // sampled approximation may differ by one encoded byte.
  #expect(abs(Int(centeredHalf) - Int(earlyQuarter)) <= 1)
  #expect(earlyQuarter > 175)
}

@Test func aRadialGradientFillIsBrightestAtItsCenter() throws {
  let gradient = VectorGradient(
    kind: .radial,
    stops: [
      VectorGradientStop(color: .white, position: 0),
      VectorGradientStop(color: .black, position: 1),
    ],
    start: VectorPoint(x: 0.5, y: 0.5),
    end: VectorPoint(x: 1, y: 0.5)
  )
  let sample = try sampled(
    filledCanvasLayer(VectorFillStyle(gradient: gradient)), width: 32, height: 32)

  let center = sample.pixels[16 * sample.bytesPerRow + 16 * 4]
  let edge = sample.pixels[16 * sample.bytesPerRow + 1 * 4]
  #expect(center > edge)
  #expect(center > 215)
}

@Test func fillOpacityDimsAFillWithoutChangingItsColor() throws {
  let opaque = try sampled(
    filledCanvasLayer(VectorFillStyle(color: .white)), width: 8, height: 8)
  let faded = try sampled(
    filledCanvasLayer(VectorFillStyle(color: .white, opacity: 0.5)), width: 8, height: 8)

  let opaqueAlpha = opaque.pixels[4 * opaque.bytesPerRow + 4 * 4 + 3]
  let fadedAlpha = faded.pixels[4 * faded.bytesPerRow + 4 * 4 + 3]
  #expect(opaqueAlpha > 250)
  #expect(fadedAlpha > 110 && fadedAlpha < 145)
}

@Test func anUnfilledObjectPaintsNothingWhereItsFillWouldBe() throws {
  var path = VectorPath(
    name: "Outline",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.1, y: 0.1)),
      VectorAnchor(position: VectorPoint(x: 0.9, y: 0.1)),
      VectorAnchor(position: VectorPoint(x: 0.9, y: 0.9)),
      VectorAnchor(position: VectorPoint(x: 0.1, y: 0.9)),
    ],
    isClosed: true,
    stroke: VectorStrokeStyle(color: .white, width: 1),
    fill: nil
  )
  path.zOrder = 0
  let layer = ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(path)]))
  )
  let sample = try sampled(layer, width: 32, height: 32)
  // The middle of the shape is well inside the outline and must stay clear.
  #expect(sample.pixels[16 * sample.bytesPerRow + 16 * 4 + 3] == 0)
}

/// A closed square inset from the canvas edge, so an outside stroke has room.
private func strokedSquareLayer(_ stroke: VectorStrokeStyle) -> ProjectLayer {
  let path = VectorPath(
    name: "Outlined",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.25, y: 0.25)),
      VectorAnchor(position: VectorPoint(x: 0.75, y: 0.25)),
      VectorAnchor(position: VectorPoint(x: 0.75, y: 0.75)),
      VectorAnchor(position: VectorPoint(x: 0.25, y: 0.75)),
    ],
    isClosed: true,
    stroke: stroke,
    fill: nil
  )
  return ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(path)]))
  )
}

@Test func strokeAlignmentDecidesWhichSideOfTheOutlineIsPainted() throws {
  let width = 8.0
  func alpha(_ alignment: VectorStrokeAlignment, atX x: Int) throws -> UInt8 {
    let sample = try sampled(
      strokedSquareLayer(
        VectorStrokeStyle(color: .white, width: width, alignment: alignment)),
      width: 64, height: 64)
    return sample.pixels[32 * sample.bytesPerRow + x * 4 + 3]
  }

  // The left edge sits at x = 16. Four pixels either side of it is inside the
  // stroke for a centered one, and on exactly one side for the others.
  #expect(try alpha(.center, atX: 14) > 200)
  #expect(try alpha(.center, atX: 18) > 200)

  #expect(try alpha(.inside, atX: 14) == 0)
  #expect(try alpha(.inside, atX: 18) > 200)

  #expect(try alpha(.outside, atX: 14) > 200)
  #expect(try alpha(.outside, atX: 18) == 0)
}

@Test func anArrowheadPaintsBeyondTheEndOfAnOpenStroke() throws {
  let line = VectorPath(
    name: "Arrow",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.5)),
      VectorAnchor(position: VectorPoint(x: 0.6, y: 0.5)),
    ],
    isClosed: false,
    stroke: VectorStrokeStyle(
      color: .white,
      width: 2,
      endArrowhead: VectorArrowhead(style: .triangle, scale: 4)
    ),
    fill: nil
  )
  let layer = ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(line)]))
  )
  let sample = try sampled(layer, width: 64, height: 64)

  // The line runs along row 32 and ends at x = 38.4. A triangular head four
  // widths long is 8 pixels deep and spreads to 4 either side, so a pixel two
  // rows off the line at x = 32 is inside the head and well outside the bare
  // two-pixel stroke.
  let besideTheLine = sample.pixels[34 * sample.bytesPerRow + 32 * 4 + 3]
  #expect(besideTheLine > 0)

  // Without the head, that same pixel is clear.
  var plain = line
  plain.stroke?.endArrowhead = nil
  let plainLayer = ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(plain)]))
  )
  let plainSample = try sampled(plainLayer, width: 64, height: 64)
  #expect(plainSample.pixels[34 * plainSample.bytesPerRow + 32 * 4 + 3] == 0)
}

@Test func anOpenPathIsAlwaysStrokedOnItsCenterLine() throws {
  // Alignment has no meaning without an inside; an open path must not lose its
  // stroke because the recipe asked for one.
  let line = VectorPath(
    name: "Open",
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.2, y: 0.5)),
      VectorAnchor(position: VectorPoint(x: 0.8, y: 0.5)),
    ],
    isClosed: false,
    stroke: VectorStrokeStyle(color: .white, width: 6, alignment: .inside),
    fill: nil
  )
  let layer = ProjectLayer(
    name: "Vector Layer",
    isEnabled: true,
    isLocked: false,
    zOrder: 1,
    content: .vector(VectorLayer(objects: [.path(line)]))
  )
  let sample = try sampled(layer, width: 64, height: 64)
  #expect(sample.pixels[32 * sample.bytesPerRow + 32 * 4 + 3] > 200)
}
