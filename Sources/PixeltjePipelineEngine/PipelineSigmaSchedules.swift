import Foundation

/// A rejected argument to a model-free pipeline operation. Adapters report it
/// as a graph error for the node that supplied the argument.
public enum PipelineOperationError: Error, LocalizedError, Equatable, Sendable {
  case invalidArgument(String)

  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let message): message
    }
  }
}

/// Reviewed noise-schedule math (ComfyUI `SIGMAS`). A schedule lists one sigma
/// per sampling boundary in sampling order, so `n` steps carry `n + 1` values
/// and a complete schedule ends at zero. None of these operations needs a
/// model: schedulers that read a denoiser's own sigma range belong to the
/// adapter that loads that denoiser.
public enum PipelineSigmaSchedules {
  public static let maximumSteps = 10_000

  /// The published Align Your Steps noise levels for ten steps.
  public enum AlignYourStepsModel: String, CaseIterable, Sendable {
    case sd1 = "SD1"
    case sdxl = "SDXL"
    case svd = "SVD"

    var noiseLevels: [Double] {
      switch self {
      case .sd1:
        [
          14.6146412293, 6.4745760956, 3.8636745985, 2.6946151520, 1.8841921177,
          1.3943805092, 0.9642583904, 0.6523686016, 0.3977456272, 0.1515232662,
          0.0291671582,
        ]
      case .sdxl:
        [
          14.6146412293, 6.3184485287, 3.7681790315, 2.1811480769, 1.3405244945,
          0.8620721141, 0.5550693289, 0.3798540708, 0.2332364134, 0.1114188177,
          0.0291671582,
        ]
      case .svd:
        [700.00, 54.5, 15.886, 7.977, 4.248, 1.789, 0.981, 0.403, 0.173, 0.034, 0.002]
      }
    }
  }

  /// Karras et al. (2022) schedule: sigmas evenly spaced in `sigma^(1/rho)`
  /// from `sigmaMax` to `sigmaMin`, followed by zero.
  public static func karras(
    steps: Int, sigmaMin: Double, sigmaMax: Double, rho: Double
  ) throws -> [Double] {
    try validate(steps: steps)
    guard sigmaMin.isFinite, sigmaMax.isFinite, sigmaMin >= 0, sigmaMax >= 0 else {
      throw PipelineOperationError.invalidArgument(
        "Karras sigmas must be finite and zero or more.")
    }
    guard rho.isFinite, rho > 0 else {
      throw PipelineOperationError.invalidArgument("Karras rho must be finite and positive.")
    }
    let minimumInverse = pow(sigmaMin, 1 / rho)
    let maximumInverse = pow(sigmaMax, 1 / rho)
    return linearlySpaced(from: 0, to: 1, count: steps).map {
      pow(maximumInverse + $0 * (minimumInverse - maximumInverse), rho)
    } + [0]
  }

  /// Sigmas evenly spaced in log space from `sigmaMax` to `sigmaMin`,
  /// followed by zero.
  public static func exponential(
    steps: Int, sigmaMin: Double, sigmaMax: Double
  ) throws -> [Double] {
    try validate(steps: steps)
    guard sigmaMin.isFinite, sigmaMax.isFinite, sigmaMin > 0, sigmaMax > 0 else {
      throw PipelineOperationError.invalidArgument(
        "Exponential schedule sigmas must be finite and positive.")
    }
    return linearlySpaced(from: log(sigmaMax), to: log(sigmaMin), count: steps).map(exp) + [0]
  }

  /// Align Your Steps (Sabour et al., 2024). Step counts other than ten
  /// interpolate the published levels log-linearly. A denoise below one keeps
  /// only the final `round(steps × denoise)` steps, and the last sigma is zero.
  public static func alignYourSteps(
    model: AlignYourStepsModel, steps: Int, denoise: Double
  ) throws -> [Double] {
    try validate(steps: steps)
    guard denoise.isFinite, (0...1).contains(denoise) else {
      throw PipelineOperationError.invalidArgument(
        "Align Your Steps denoise must be between 0 and 1.")
    }
    var totalSteps = steps
    if denoise < 1 {
      if denoise <= 0 { return [] }
      totalSteps = Int((Double(steps) * denoise).rounded(.toNearestOrEven))
    }
    var sigmas = model.noiseLevels
    if steps + 1 != sigmas.count {
      sigmas = logLinearInterpolation(sigmas, count: steps + 1)
    }
    sigmas = Array(sigmas.suffix(totalSteps + 1))
    sigmas[sigmas.count - 1] = 0
    return sigmas
  }

  /// Splits at a step boundary. Both halves keep the boundary sigma, so the
  /// low half continues exactly where the high half stops.
  public static func split(
    _ sigmas: [Double], atStep step: Int
  ) throws -> (high: [Double], low: [Double]) {
    guard (0...maximumSteps).contains(step) else {
      throw PipelineOperationError.invalidArgument(
        "Split step must be between 0 and \(maximumSteps).")
    }
    return (Array(sigmas.prefix(step + 1)), Array(sigmas.dropFirst(step)))
  }

  /// Splits so that the low half holds the final `round(steps × denoise)`
  /// steps. As in ComfyUI, a split that leaves the low half no steps also
  /// leaves the high half empty.
  public static func split(
    _ sigmas: [Double], denoise: Double
  ) throws -> (high: [Double], low: [Double]) {
    guard denoise.isFinite, (0...1).contains(denoise) else {
      throw PipelineOperationError.invalidArgument("Split denoise must be between 0 and 1.")
    }
    let steps = max(sigmas.count - 1, 0)
    let totalSteps = Int((Double(steps) * denoise).rounded(.toNearestOrEven))
    let high = totalSteps == 0 ? [] : Array(sigmas.prefix(max(sigmas.count - totalSteps, 0)))
    return (high, Array(sigmas.suffix(totalSteps + 1)))
  }

  /// Reverses a schedule for inversion. A leading zero becomes 0.0001 so the
  /// first step still has a nonzero noise level.
  public static func flipped(_ sigmas: [Double]) -> [Double] {
    var result = Array(sigmas.reversed())
    if result.first == 0 { result[0] = 0.0001 }
    return result
  }

  /// Ends a truncated schedule at zero so sampling returns a fully denoised
  /// latent instead of leftover noise.
  public static func denoisedToZero(_ sigmas: [Double]) -> [Double] {
    var result = sigmas
    if !result.isEmpty { result[result.count - 1] = 0 }
    return result
  }

  private static func validate(steps: Int) throws {
    guard (1...maximumSteps).contains(steps) else {
      throw PipelineOperationError.invalidArgument(
        "Schedule steps must be between 1 and \(maximumSteps).")
    }
  }

  /// Matches `torch.linspace`: a single value is the start.
  private static func linearlySpaced(from start: Double, to end: Double, count: Int) -> [Double] {
    guard count > 1 else { return [start] }
    let step = (end - start) / Double(count - 1)
    return (0..<count).map { index in
      index == count - 1 ? end : start + Double(index) * step
    }
  }

  /// Interpolates descending levels linearly in log space over evenly spaced
  /// positions, preserving both endpoints.
  private static func logLinearInterpolation(_ levels: [Double], count: Int) -> [Double] {
    let logarithms = levels.reversed().map { log($0) }
    let positions = linearlySpaced(from: 0, to: 1, count: count)
    let intervals = Double(logarithms.count - 1)
    let interpolated = positions.map { position -> Double in
      let scaled = position * intervals
      let lower = min(Int(scaled.rounded(.down)), logarithms.count - 1)
      let upper = min(lower + 1, logarithms.count - 1)
      let fraction = scaled - Double(lower)
      return exp(logarithms[lower] + (logarithms[upper] - logarithms[lower]) * fraction)
    }
    return interpolated.reversed()
  }
}
