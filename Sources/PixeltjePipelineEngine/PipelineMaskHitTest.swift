import Foundation

/// Finds the highest-confidence labeled mask covering a normalized point.
public enum PipelineMaskHitTest {
  public static func pick(
    masks: [PipelineLabeledMask], x: Double, y: Double,
    threshold: Float, radius: Int
  ) throws -> PipelineLabeledMask? {
    try index(masks: masks, x: x, y: y, threshold: threshold, radius: radius).map { masks[$0] }
  }

  public static func index(
    masks: [PipelineLabeledMask], x: Double, y: Double,
    threshold: Float, radius: Int
  ) throws -> Int? {
    guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
      throw PipelineEngineError.invalidInvocation(
        "Mask Hit Test coordinates must be between 0 and 1.")
    }
    guard threshold.isFinite, threshold > 0, threshold <= 1, (0...16).contains(radius) else {
      throw PipelineEngineError.invalidInvocation("Invalid mask hit-test threshold or radius.")
    }
    var chosen: Int?
    for (index, candidate) in masks.enumerated() {
      let mask = candidate.mask
      let centerX = min(Int(x * Double(mask.width)), mask.width - 1)
      let centerY = min(Int(y * Double(mask.height)), mask.height - 1)
      let left = max(0, centerX - radius)
      let right = min(mask.width - 1, centerX + radius)
      let top = max(0, centerY - radius)
      let bottom = min(mask.height - 1, centerY + radius)
      var hit = false
      for py in top...bottom where !hit {
        for px in left...right where (px - centerX) * (px - centerX)
          + (py - centerY) * (py - centerY) <= radius * radius {
          if mask.coverage[py * mask.width + px] >= threshold {
            hit = true
            break
          }
        }
      }
      if hit {
        if let current = chosen {
          if candidate.score > masks[current].score { chosen = index }
        } else {
          chosen = index
        }
      }
    }
    return chosen
  }
}
