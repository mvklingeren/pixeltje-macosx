import Foundation
import Testing

@testable import PixeltjeMacDomain

/// Comparisons use documented tolerances rather than exact equality: the
/// solve is iterative, and the answer it converges to is approached rather
/// than landed on.
private let levelTolerance: Float = 0.01
private let rampTolerance: Float = 0.03

private struct Field {
  var width: Int
  var height: Int
  var values: [Float]

  init(width: Int, height: Int, _ value: (Int, Int) -> Float) {
    self.width = width
    self.height = height
    values = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let level = value(x, y)
        let base = (y * width + x) * 4
        values[base] = level
        values[base + 1] = level
        values[base + 2] = level
        values[base + 3] = 1
      }
    }
  }

  func red(_ x: Int, _ y: Int) -> Float { values[(y * width + x) * 4] }
  func alpha(_ x: Int, _ y: Int) -> Float { values[(y * width + x) * 4 + 3] }
}

/// Full coverage over a centred block, zero elsewhere. The block is well
/// inside the buffer, which is what gives the solve a ring to meet.
private func centredCoverage(width: Int, height: Int, inset: Int) -> [Float] {
  var coverage = [Float](repeating: 0, count: width * height)
  for y in inset..<(height - inset) {
    for x in inset..<(width - inset) {
      coverage[y * width + x] = 1
    }
  }
  return coverage
}

private func solved(
  destination: Field,
  source: Field? = nil,
  coverage: [Float],
  blend: HealBlendMethod = .seamless,
  iterations: Int = 96
) throws -> Field {
  let values = try #require(
    HealSolver.solve(
      destination: destination.values,
      source: source?.values,
      coverage: coverage,
      width: destination.width,
      height: destination.height,
      blend: blend,
      iterations: iterations
    ))
  var result = destination
  result.values = values
  return result
}

@Test func aSpotHealLiftsABlemishOffAFlatField() throws {
  let size = 32
  // A uniform field with a dark spot in the middle, and coverage over the spot.
  let destination = Field(width: size, height: size) { x, y in
    (12..<20).contains(x) && (12..<20).contains(y) ? 0.08 : 0.5
  }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  let result = try solved(destination: destination, coverage: coverage)

  // The smoothest surface meeting a constant boundary is that constant.
  for y in 12..<20 {
    for x in 12..<20 {
      #expect(abs(result.red(x, y) - 0.5) < levelTolerance)
    }
  }
  // Outside the coverage nothing moved.
  #expect(result.red(2, 2) == 0.5)
  #expect(result.alpha(16, 16) > 0.99)
}

@Test func aSpotHealPreservesABrightnessGradient() throws {
  let size = 32
  // A linear ramp is harmonic, so the exact answer inside the covered region
  // is the ramp itself. A solver that simply averaged the boundary would
  // flatten it into a constant patch and show as a visible plateau.
  let destination = Field(width: size, height: size) { x, _ in Float(x) / Float(size) }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  let result = try solved(destination: destination, coverage: coverage)

  for y in 12..<20 {
    for x in 12..<20 {
      #expect(abs(result.red(x, y) - Float(x) / Float(size)) < rampTolerance)
    }
  }
}

@Test func aSourcePointHealTakesTheDestinationsLevel() throws {
  let size = 32
  let destination = Field(width: size, height: size) { _, _ in 0.7 }
  // Uniformly darker than the destination: its gradients are zero, so the
  // solve should land on the destination's level rather than the source's.
  let source = Field(width: size, height: size) { _, _ in 0.2 }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  let result = try solved(destination: destination, source: source, coverage: coverage)

  #expect(abs(result.red(16, 16) - 0.7) < levelTolerance)
}

@Test func aSourcePointHealCarriesTheSourcesDetail() throws {
  let size = 32
  let destination = Field(width: size, height: size) { _, _ in 0.6 }
  // Vertical stripes: detail the destination does not have, at a level the
  // destination does not have either.
  let stripe = { (x: Int) -> Float in x % 8 < 4 ? 0.18 : 0.30 }
  let source = Field(width: size, height: size) { x, _ in stripe(x) }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  let result = try solved(destination: destination, source: source, coverage: coverage)

  // The stripe edges survive: the step across a boundary in the interior is
  // reproduced with the source's sign and something close to its size.
  let step = result.red(16, 16) - result.red(15, 16)
  let sourceStep = stripe(16) - stripe(15)
  #expect(sourceStep != 0)
  #expect(step * sourceStep > 0)
  #expect(abs(step - sourceStep) < 0.05)
  // And it is not simply the source pasted in: the level came from the
  // destination, which is far brighter than the source everywhere.
  #expect(result.red(16, 16) > 0.4)
}

@Test func aColorMatchedHealAlsoLandsOnTheDestinationsLevel() throws {
  let size = 32
  let destination = Field(width: size, height: size) { _, _ in 0.65 }
  let source = Field(width: size, height: size) { x, _ in x % 6 < 3 ? 0.2 : 0.26 }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  let result = try solved(
    destination: destination, source: source, coverage: coverage, blend: .colorMatched)

  // Looser than the solve's tolerance on purpose: this path trades exactness
  // at the boundary for a single blur, and the test should say so.
  #expect(abs(result.red(16, 16) - 0.65) < 0.08)
}

@Test func aSpotHealIgnoresAColorMatchedSetting() throws {
  let size = 32
  let destination = Field(width: size, height: size) { x, y in
    (12..<20).contains(x) && (12..<20).contains(y) ? 0.05 : 0.45
  }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  // Colour matching needs a source to take detail from. With none it would
  // reduce to the destination — that is, to leaving the blemish in place — so
  // a spot heal solves regardless of what the panel is set to.
  let result = try solved(
    destination: destination, coverage: coverage, blend: .colorMatched)

  #expect(abs(result.red(16, 16) - 0.45) < levelTolerance)
}

@Test func aBakedPatchLeavesNoSeamWhereItsCoverageFades() throws {
  let size = 32
  let destination = Field(width: size, height: size) { x, y in
    (12..<20).contains(x) && (12..<20).contains(y) ? 0.08 : 0.5
  }
  // A soft edge: full coverage over the blemish, half over the ring outside it.
  var coverage = [Float](repeating: 0, count: size * size)
  for y in 11..<21 {
    for x in 11..<21 {
      coverage[y * size + x] = (12..<20).contains(x) && (12..<20).contains(y) ? 1 : 0.5
    }
  }

  let patch = HealSolver.applyingCoverage(
    coverage, to: try solved(destination: destination, coverage: coverage).values)

  // Source-over the patch onto what it was solved against, which is what the
  // render path does once the patch is a placed raster.
  func composited(_ x: Int, _ y: Int) -> Float {
    let index = (y * size + x) * 4
    let alpha = patch[index + 3]
    return patch[index] + (1 - alpha) * destination.values[index]
  }

  // The blemish is gone, and every pixel across the heal and its fading edge
  // reads as the field it sits in: a partial alpha in the feather zone blends
  // a patch that already equals the destination there.
  for x in 9..<23 {
    #expect(abs(composited(x, 16) - 0.5) < levelTolerance)
  }
  #expect(patch[(16 * size + 16) * 4 + 3] == 1)
  #expect(abs(patch[(11 * size + 16) * 4 + 3] - 0.5) < 0.0001)
  #expect(patch[(2 * size + 2) * 4 + 3] == 0)
}

@Test func applyingCoverageRefusesAMismatchedBuffer() {
  let values = [Float](repeating: 1, count: 16)

  #expect(HealSolver.applyingCoverage([1, 1], to: values) == values)
}

@Test func nothingIsSolvedWhenNothingIsCovered() {
  let size = 16
  let destination = Field(width: size, height: size) { _, _ in 0.5 }

  #expect(
    HealSolver.solve(
      destination: destination.values,
      source: nil,
      coverage: [Float](repeating: 0, count: size * size),
      width: size,
      height: size,
      blend: .seamless,
      iterations: 8
    ) == nil)
}

@Test func mismatchedBufferSizesAreRefusedRatherThanReadPast() {
  let destination = [Float](repeating: 0.5, count: 8 * 8 * 4)

  #expect(
    HealSolver.solve(
      destination: destination,
      source: nil,
      coverage: [Float](repeating: 1, count: 4),
      width: 8,
      height: 8,
      blend: .seamless,
      iterations: 4
    ) == nil)
  #expect(
    HealSolver.solve(
      destination: destination,
      source: [Float](repeating: 0.1, count: 12),
      coverage: [Float](repeating: 1, count: 8 * 8),
      width: 8,
      height: 8,
      blend: .seamless,
      iterations: 4
    ) == nil)
}

@Test func theInteriorNeverReachesTheBorder() {
  let size = 6
  let mask = HealSolver.interiorMask(
    coverage: [Float](repeating: 1, count: size * size), width: size, height: size)

  // An interior pixel on the edge would have to clamp a missing neighbour,
  // which silently turns the boundary condition into a reflecting one.
  for index in 0..<size {
    #expect(!mask[index])
    #expect(!mask[(size - 1) * size + index])
    #expect(!mask[index * size])
    #expect(!mask[index * size + size - 1])
  }
  #expect(mask[2 * size + 2])
}

@Test func coverageBelowTheThresholdStaysBoundary() {
  let size = 8
  var coverage = [Float](repeating: 0, count: size * size)
  coverage[3 * size + 3] = HealSolver.interiorThreshold - 0.01
  coverage[3 * size + 4] = HealSolver.interiorThreshold

  let mask = HealSolver.interiorMask(coverage: coverage, width: size, height: size)

  #expect(!mask[3 * size + 3])
  #expect(mask[3 * size + 4])
}

@Test func anUnstableSolveIsClampedRatherThanStored() throws {
  let size = 32
  let destination = Field(width: size, height: size) { _, _ in 0.5 }
  // Source gradients far steeper than the destination's boundary can admit.
  // A Poisson solve is unbounded by construction, so the result has to be
  // brought back into the range the working space and the encoder accept.
  let source = Field(width: size, height: size) { x, y in
    (x + y) % 2 == 0 ? -40 : 60
  }
  let coverage = centredCoverage(width: size, height: size, inset: 10)

  let result = try solved(destination: destination, source: source, coverage: coverage)

  for value in result.values.enumerated() {
    #expect(value.element.isFinite)
    if value.offset % 4 == 3 {
      #expect(value.element >= 0 && value.element <= 1)
    } else {
      #expect(value.element >= -0.5 && value.element <= 16)
    }
  }
}
