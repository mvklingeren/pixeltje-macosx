import Foundation
import PixeltjePipelineEngine
import Testing

// Reference values were produced with ComfyUI's scheduler formulas in
// PyTorch/NumPy float64 and are compared with a documented tolerance.
private func expectClose(
  _ actual: [Double], _ expected: [Double], tolerance: Double = 1e-6
) {
  #expect(actual.count == expected.count)
  for (value, reference) in zip(actual, expected) {
    #expect(abs(value - reference) <= tolerance * max(1, abs(reference)))
  }
}

@Test func karrasScheduleMatchesTheReferenceFormula() throws {
  let sigmas = try PipelineSigmaSchedules.karras(
    steps: 20, sigmaMin: 0.0291675, sigmaMax: 14.614642, rho: 7)
  #expect(sigmas.count == 21)
  expectClose(Array(sigmas.prefix(4)), [14.614642, 11.7253685, 9.34020828, 7.38362391])
  expectClose(Array(sigmas.suffix(3)), [0.0484818628, 0.0291675, 0])
  expectClose(
    try PipelineSigmaSchedules.karras(
      steps: 1, sigmaMin: 0.0291675, sigmaMax: 14.614642, rho: 7),
    [14.614642, 0])
}

@Test func exponentialScheduleIsEvenlySpacedInLogSpace() throws {
  let sigmas = try PipelineSigmaSchedules.exponential(
    steps: 20, sigmaMin: 0.0291675, sigmaMax: 14.614642)
  #expect(sigmas.count == 21)
  expectClose(Array(sigmas.prefix(3)), [14.614642, 10.5363154, 7.59607671])
  expectClose(Array(sigmas.suffix(2)), [0.0291675, 0])
  #expect(throws: PipelineOperationError.self) {
    try PipelineSigmaSchedules.exponential(steps: 20, sigmaMin: 0, sigmaMax: 14.614642)
  }
}

@Test func alignYourStepsUsesPublishedLevelsAndInterpolatesOtherStepCounts() throws {
  let ten = try PipelineSigmaSchedules.alignYourSteps(model: .sd1, steps: 10, denoise: 1)
  expectClose(Array(ten.prefix(2)), [14.6146412293, 6.4745760956])
  #expect(ten.count == 11)
  #expect(ten.last == 0)

  let partial = try PipelineSigmaSchedules.alignYourSteps(model: .sdxl, steps: 4, denoise: 0.5)
  expectClose(partial, [0.862072114, 0.297650468, 0])
  #expect(try PipelineSigmaSchedules.alignYourSteps(model: .svd, steps: 7, denoise: 0).isEmpty)
}

@Test func scheduleSurgeryKeepsBoundarySigmas() throws {
  let sigmas: [Double] = [10, 6, 3, 1, 0.5, 0]
  let split = try PipelineSigmaSchedules.split(sigmas, atStep: 2)
  #expect(split.high == [10, 6, 3])
  #expect(split.low == [3, 1, 0.5, 0])

  let byDenoise = try PipelineSigmaSchedules.split(sigmas, denoise: 0.4)
  #expect(byDenoise.high == [10, 6, 3, 1])
  #expect(byDenoise.low == [1, 0.5, 0])

  // ComfyUI's slice leaves the high half empty when the low half has no steps.
  let none = try PipelineSigmaSchedules.split(sigmas, denoise: 0)
  #expect(none.high.isEmpty)
  #expect(none.low == [0])

  #expect(PipelineSigmaSchedules.flipped(sigmas) == [0.0001, 0.5, 1, 3, 6, 10])
  #expect(PipelineSigmaSchedules.denoisedToZero([10, 6, 3]) == [10, 6, 0])
  #expect(PipelineSigmaSchedules.denoisedToZero([]).isEmpty)
}

@Test func emptyLatentsUseTheirFamilyCompression() throws {
  let image = try PipelineLatent.emptyImage(width: 1024, height: 768, batchSize: 2)
  #expect(image.shape == [2, nil, 96, 128])
  #expect(image.samples == nil)

  let flux = try PipelineLatent.emptyFLUX2Image(width: 1024, height: 1024, batchSize: 1)
  #expect(flux.shape == [1, 128, 64, 64])

  let hunyuan = try PipelineLatent.emptyHunyuanVideo(
    width: 848, height: 480, length: 25, batchSize: 1)
  #expect(hunyuan.shape == [1, 16, 7, 60, 106])

  let ltxv = try PipelineLatent.emptyLTXVVideo(
    width: 768, height: 512, length: 97, batchSize: 1)
  #expect(ltxv.shape == [1, 128, 13, 16, 24])
}

@Test func latentBatchSelectionClampsAndTracksPositions() throws {
  let latent = try PipelineLatent(
    batchSize: 3, channels: 1, height: 1, width: 2, spatialScale: 8,
    samples: [1, 2, 3, 4, 5, 6])
  let selected = try latent.selectingBatch(from: 1, length: 5)
  #expect(selected.batchSize == 2)
  #expect(selected.samples == [3, 4, 5, 6])
  #expect(selected.batchIndices == [1, 2])

  let last = try latent.selectingBatch(from: -1, length: 1)
  #expect(last.samples == [5, 6])
  #expect(last.batchIndices == [2])

  let beforeStart = try latent.selectingBatch(from: -10, length: 1)
  #expect(beforeStart.samples == [1, 2])
  #expect(beforeStart.batchIndices == [0])

  let repeated = try selected.repeated(2)
  #expect(repeated.samples == [3, 4, 5, 6, 3, 4, 5, 6])
  #expect(repeated.batchIndices == [1, 2, 3, 4])
}

@Test func latentResamplingMatchesPyTorchInterpolation() throws {
  let latent = try PipelineLatent(
    batchSize: 1, channels: 1, height: 2, width: 2, spatialScale: 8,
    samples: [0, 1, 2, 3])
  let nearest = try latent.resized(width: 4, height: 4, method: "nearest-exact")
  #expect(nearest.samples == [0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3])

  let bilinear = try latent.resized(width: 4, height: 1, method: "bilinear")
  let expected: [Float] = [1, 1.25, 1.75, 2]
  for (value, reference) in zip(bilinear.samples ?? [], expected) {
    #expect(abs(value - reference) < 1e-6)
  }

  let area = try latent.resized(width: 1, height: 1, method: "area")
  #expect(area.samples == [1.5])
  #expect(throws: PipelineOperationError.self) {
    try latent.resized(width: 4, height: 4, method: "lanczos")
  }
}

@Test func bislerpInterpolatesChannelVectorsSpherically() throws {
  // Orthogonal unit vectors meet halfway at 45 degrees with unit length.
  let latent = try PipelineLatent(
    batchSize: 1, channels: 2, height: 1, width: 2, spatialScale: 8,
    samples: [1, 0, 0, 1])
  let resized = try latent.resized(width: 3, height: 1, method: "bislerp")
  let expected: [Float] = [1, 0.70710678, 0, 0, 0.70710678, 1]
  #expect(resized.samples?.count == expected.count)
  for (value, reference) in zip(resized.samples ?? [], expected) {
    #expect(abs(value - reference) < 1e-5)
  }

  // As in ComfyUI, parallel neighbours return the first vector unchanged.
  let parallel = try PipelineLatent(
    batchSize: 1, channels: 2, height: 1, width: 2, spatialScale: 8,
    samples: [1, 3, 1, 3])
  #expect(try parallel.resized(width: 4, height: 1, method: "bislerp").samples
    == [1, 1, 1, 3, 1, 1, 1, 3])
}
