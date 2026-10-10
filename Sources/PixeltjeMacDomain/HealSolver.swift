import Foundation

/// Reconstructs the pixels a heal replaces.
///
/// Deliberately pure: buffers of `Float` in, a buffer of `Float` out, no Core
/// Image, no Metal, no actor. A heal is solved once per commit rather than per
/// frame, so this never sits in the interactive render path, and keeping it
/// framework-free is what lets the arithmetic be tested directly instead of
/// inferred from a screenshot.
///
/// Spot healing and source-point healing are the same equation with a
/// different right-hand side. Both solve
///
///     ∇²f = g   inside the painted region
///     f = destination   on its boundary
///
/// with `g` zero for a spot heal — giving the smoothest surface that meets the
/// surrounding pixels — and `g` the source region's own Laplacian for a
/// source-point heal, which reproduces the source's texture while taking the
/// destination's colour and brightness. One solver therefore serves both
/// modes, and the mode is only a question of what `g` is filled with.
public enum HealSolver {
  /// Coverage at or above this counts as interior: a pixel the solve replaces.
  /// Below it the pixel holds its destination value and acts as boundary.
  ///
  /// The soft edge of the coverage is not lost by this. It is applied when the
  /// patch is composited, so the feather zone blends a patch that already
  /// equals the destination there — which is exactly a soft transition.
  public static let interiorThreshold: Float = 0.5

  /// Channels per pixel. Premultiplied RGBA throughout: the Laplacian is
  /// linear, so premultiplied values solve correctly without unpremultiplying,
  /// and the result is in the form the raster encoder expects.
  public static let channels = 4

  /// The solved patch, or `nil` when there is nothing to solve.
  ///
  /// - Parameters:
  ///   - destination: Premultiplied RGBA of the region as it stands, row-major
  ///     from the bottom-left, `width * height * 4` values.
  ///   - source: Premultiplied RGBA of the source region for a source-point
  ///     heal, in the same layout, or `nil` for a spot heal.
  ///   - coverage: Painted coverage in `0...1`, `width * height` values.
  ///   - iterations: Relaxation sweeps per pyramid level.
  public static func solve(
    destination: [Float],
    source: [Float]?,
    coverage: [Float],
    width: Int,
    height: Int,
    blend: HealBlendMethod,
    iterations: Int
  ) -> [Float]? {
    guard width > 2, height > 2,
      destination.count == width * height * channels,
      coverage.count == width * height,
      source == nil || source?.count == destination.count
    else { return nil }

    let interior = interiorMask(coverage: coverage, width: width, height: height)
    guard interior.contains(true) else { return nil }

    // A colour-matched blend needs something to take detail from. Without a
    // source it would reduce to the destination, so a spot heal always solves
    // whatever the panel is set to.
    if blend == .colorMatched, let source {
      return colorMatched(
        destination: destination, source: source, interior: interior,
        width: width, height: height)
    }

    let sweeps = min(
      max(iterations, HealLimits.minimumSolverIterations), HealLimits.maximumSolverIterations)
    return seamless(
      destination: destination, source: source, interior: interior,
      width: width, height: height, iterations: sweeps)
  }

  /// Which pixels the solve is free to change.
  ///
  /// The one-pixel border is always boundary. An interior pixel touching the
  /// edge of the buffer would have to clamp its missing neighbour, which turns
  /// the Dirichlet condition into a reflecting one and lets the patch drift
  /// away from the image it has to meet. Callers dilate the patch bounds past
  /// the coverage for the same reason; this makes it true regardless.
  static func interiorMask(coverage: [Float], width: Int, height: Int) -> [Bool] {
    var interior = [Bool](repeating: false, count: width * height)
    guard width > 2, height > 2 else { return interior }
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let index = y * width + x
        let value = coverage[index]
        interior[index] = value.isFinite && value >= interiorThreshold
      }
    }
    return interior
  }

  // MARK: - Gradient-domain solve

  private static func seamless(
    destination: [Float],
    source: [Float]?,
    interior: [Bool],
    width: Int,
    height: Int,
    iterations: Int
  ) -> [Float] {
    // Coarse-to-fine. Plain relaxation moves information one pixel per sweep,
    // so on a patch of any size the low-frequency part of the answer would
    // take as many sweeps as the patch is wide. Solving a small copy first and
    // carrying it up as the next level's starting guess is what makes the cost
    // proportional to the patch rather than to its square.
    var levels: [Level] = [
      Level(
        destination: destination, source: source, interior: interior,
        width: width, height: height)
    ]
    while let finest = levels.last,
      finest.width > 16, finest.height > 16, levels.count < 8
    {
      levels.append(finest.halved())
    }

    var solution: [Float]?
    var solvedWidth = 0
    for index in stride(from: levels.count - 1, through: 0, by: -1) {
      let level = levels[index]
      var guess: [Float]
      if let coarser = solution {
        guess = level.upsampling(coarser, fromWidth: solvedWidth)
      } else {
        guess = level.initialGuess()
      }
      level.relax(&guess, iterations: iterations)
      solution = guess
      solvedWidth = level.width
    }
    var result = solution ?? destination
    clamp(&result, destination: destination)
    return result
  }

  /// One resolution of the problem.
  private struct Level {
    var destination: [Float]
    var source: [Float]?
    var interior: [Bool]
    var width: Int
    var height: Int

    /// The same problem at half the resolution.
    func halved() -> Level {
      let newWidth = max(width / 2, 1)
      let newHeight = max(height / 2, 1)
      let count = newWidth * newHeight * HealSolver.channels
      var nextDestination = [Float](repeating: 0, count: count)
      var nextSource: [Float]? =
        source == nil ? nil : [Float](repeating: 0, count: count)
      var nextInterior = [Bool](repeating: false, count: newWidth * newHeight)

      for y in 0..<newHeight {
        for x in 0..<newWidth {
          let sourceX = min(x * 2, width - 1)
          let sourceY = min(y * 2, height - 1)
          let neighbours = [
            sourceY * width + sourceX,
            sourceY * width + min(sourceX + 1, width - 1),
            min(sourceY + 1, height - 1) * width + sourceX,
            min(sourceY + 1, height - 1) * width + min(sourceX + 1, width - 1),
          ]
          let target = y * newWidth + x
          for channel in 0..<HealSolver.channels {
            var destinationSum: Float = 0
            var sourceSum: Float = 0
            for neighbour in neighbours {
              destinationSum += destination[neighbour * HealSolver.channels + channel]
              if let source { sourceSum += source[neighbour * HealSolver.channels + channel] }
            }
            let offset = target * HealSolver.channels + channel
            nextDestination[offset] = destinationSum / 4
            if nextSource != nil { nextSource?[offset] = sourceSum / 4 }
          }
          // A coarse pixel is interior only when its whole 2×2 footprint is.
          // Growing the region on the way down would let the coarse solution
          // overwrite pixels the fine level means to keep.
          nextInterior[target] = neighbours.allSatisfy { interior[$0] }
        }
      }
      // The border stays boundary at every level, for the reason
      // `interiorMask` gives.
      var level = Level(
        destination: nextDestination, source: nextSource, interior: nextInterior,
        width: newWidth, height: newHeight)
      level.sealBorder()
      return level
    }

    mutating func sealBorder() {
      guard width > 0, height > 0 else { return }
      for x in 0..<width {
        interior[x] = false
        interior[(height - 1) * width + x] = false
      }
      for y in 0..<height {
        interior[y * width] = false
        interior[y * width + width - 1] = false
      }
    }

    /// Destination everywhere, with the interior filled from the mean of the
    /// boundary it has to meet. A constant start costs the relaxation far
    /// fewer sweeps than starting from zero or from the destination's own
    /// blemish.
    func initialGuess() -> [Float] {
      var guess = destination
      var sums = [Double](repeating: 0, count: HealSolver.channels)
      var count = 0
      for index in 0..<(width * height) where !interior[index] {
        for channel in 0..<HealSolver.channels {
          sums[channel] += Double(destination[index * HealSolver.channels + channel])
        }
        count += 1
      }
      guard count > 0 else { return guess }
      let means = sums.map { Float($0 / Double(count)) }
      for index in 0..<(width * height) where interior[index] {
        for channel in 0..<HealSolver.channels {
          guess[index * HealSolver.channels + channel] = means[channel]
        }
      }
      return guess
    }

    /// A coarser solution as this level's starting guess, bilinearly.
    func upsampling(_ coarse: [Float], fromWidth coarseWidth: Int) -> [Float] {
      var guess = destination
      let coarseHeight = coarseWidth > 0 ? coarse.count / (coarseWidth * HealSolver.channels) : 0
      guard coarseWidth > 0, coarseHeight > 0 else { return initialGuess() }
      let scaleX = Double(coarseWidth) / Double(width)
      let scaleY = Double(coarseHeight) / Double(height)
      for y in 0..<height {
        for x in 0..<width {
          let index = y * width + x
          guard interior[index] else { continue }
          let sampleX = (Double(x) + 0.5) * scaleX - 0.5
          let sampleY = (Double(y) + 0.5) * scaleY - 0.5
          let x0 = min(max(Int(sampleX.rounded(.down)), 0), coarseWidth - 1)
          let y0 = min(max(Int(sampleY.rounded(.down)), 0), coarseHeight - 1)
          let x1 = min(x0 + 1, coarseWidth - 1)
          let y1 = min(y0 + 1, coarseHeight - 1)
          let fractionX = Float(min(max(sampleX - Double(x0), 0), 1))
          let fractionY = Float(min(max(sampleY - Double(y0), 0), 1))
          for channel in 0..<HealSolver.channels {
            let topLeft = coarse[(y0 * coarseWidth + x0) * HealSolver.channels + channel]
            let topRight = coarse[(y0 * coarseWidth + x1) * HealSolver.channels + channel]
            let bottomLeft = coarse[(y1 * coarseWidth + x0) * HealSolver.channels + channel]
            let bottomRight = coarse[(y1 * coarseWidth + x1) * HealSolver.channels + channel]
            let top = topLeft + (topRight - topLeft) * fractionX
            let bottom = bottomLeft + (bottomRight - bottomLeft) * fractionX
            guess[index * HealSolver.channels + channel] = top + (bottom - top) * fractionY
          }
        }
      }
      return guess
    }

    /// Gauss-Seidel sweeps of `∇²f = g`, in place, over interior pixels only.
    ///
    /// Gauss-Seidel rather than Jacobi because it reads the values written
    /// earlier in the same sweep, which roughly halves the sweeps needed and
    /// costs no second buffer.
    func relax(_ field: inout [Float], iterations: Int) {
      guard width > 2, height > 2 else { return }
      let guidance = self.guidance()
      for _ in 0..<iterations {
        for y in 1..<(height - 1) {
          for x in 1..<(width - 1) {
            let index = y * width + x
            guard interior[index] else { continue }
            let left = (index - 1) * HealSolver.channels
            let right = (index + 1) * HealSolver.channels
            let down = (index - width) * HealSolver.channels
            let up = (index + width) * HealSolver.channels
            let base = index * HealSolver.channels
            for channel in 0..<HealSolver.channels {
              let sum =
                field[left + channel] + field[right + channel]
                + field[down + channel] + field[up + channel]
              let target = guidance.map { $0[base + channel] } ?? 0
              field[base + channel] = (sum - target) * 0.25
            }
          }
        }
      }
    }

    /// The right-hand side: the source region's Laplacian, or `nil` for a
    /// spot heal, whose right-hand side is zero everywhere.
    private func guidance() -> [Float]? {
      guard let source else { return nil }
      var result = [Float](repeating: 0, count: width * height * HealSolver.channels)
      guard width > 2, height > 2 else { return result }
      for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
          let index = y * width + x
          guard interior[index] else { continue }
          let base = index * HealSolver.channels
          for channel in 0..<HealSolver.channels {
            let centre = source[base + channel]
            let sum =
              source[(index - 1) * HealSolver.channels + channel]
              + source[(index + 1) * HealSolver.channels + channel]
              + source[(index - width) * HealSolver.channels + channel]
              + source[(index + width) * HealSolver.channels + channel]
            result[base + channel] = sum - 4 * centre
          }
        }
      }
      return result
    }
  }

  // MARK: - Colour-matched blend

  /// `source + blur(destination − source)`.
  ///
  /// The blur carries the destination's low frequencies onto the source's
  /// detail, which is most of what the solve achieves and costs three box
  /// passes instead of a relaxation. It gives up the solve's exactness at the
  /// boundary, so a patch straddling a strong edge shows it.
  private static func colorMatched(
    destination: [Float],
    source: [Float],
    interior: [Bool],
    width: Int,
    height: Int
  ) -> [Float] {
    var difference = [Float](repeating: 0, count: width * height * channels)
    for index in 0..<(width * height) {
      for channel in 0..<channels {
        let offset = index * channels + channel
        difference[offset] = destination[offset] - source[offset]
      }
    }
    let radius = max(2, min(width, height) / 4)
    // Three box passes approximate a Gaussian closely enough for a correction
    // term, at a cost independent of the radius.
    for _ in 0..<3 {
      difference = boxBlur(difference, width: width, height: height, radius: radius)
    }
    var result = destination
    for index in 0..<(width * height) where interior[index] {
      for channel in 0..<channels {
        let offset = index * channels + channel
        result[offset] = source[offset] + difference[offset]
      }
    }
    clamp(&result, destination: destination)
    return result
  }

  /// A separable box blur with clamped edges, over interleaved channels.
  static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int)
    -> [Float]
  {
    guard radius > 0, width > 0, height > 0,
      values.count == width * height * channels
    else { return values }
    var horizontal = [Float](repeating: 0, count: values.count)
    let window = Float(radius * 2 + 1)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<channels {
          var sum: Float = 0
          for offset in -radius...radius {
            let sampleX = min(max(x + offset, 0), width - 1)
            sum += values[(y * width + sampleX) * channels + channel]
          }
          horizontal[(y * width + x) * channels + channel] = sum / window
        }
      }
    }
    var vertical = [Float](repeating: 0, count: values.count)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<channels {
          var sum: Float = 0
          for offset in -radius...radius {
            let sampleY = min(max(y + offset, 0), height - 1)
            sum += horizontal[(sampleY * width + x) * channels + channel]
          }
          vertical[(y * width + x) * channels + channel] = sum / window
        }
      }
    }
    return vertical
  }

  // MARK: - Coverage

  /// Premultiplies the painted coverage into a solved patch.
  ///
  /// The patch is stored with its visible shape already in its own alpha,
  /// rather than opaque beside a mask the renderer evaluates. Because the
  /// values are premultiplied, scaling all four channels by coverage is
  /// exactly the source-over blend that mask would have produced:
  ///
  ///     result = coverage · patch + (1 − coverage · patchAlpha) · destination
  ///
  /// and in the feather zone the solve has already returned the destination's
  /// own pixels, so a partial alpha there blends a patch that matches what is
  /// beneath it. That is what leaves no seam at the edge of a heal. A
  /// committed shape can never change, so evaluating it again on every frame
  /// would be a canvas-sized mask render per patch for no gain.
  public static func applyingCoverage(_ coverage: [Float], to values: [Float]) -> [Float] {
    guard values.count == coverage.count * channels else { return values }
    var result = values
    for index in 0..<coverage.count {
      let amount = min(max(coverage[index].isFinite ? coverage[index] : 0, 0), 1)
      for channel in 0..<channels {
        result[index * channels + channel] *= amount
      }
    }
    return result
  }

  // MARK: - Result hygiene

  /// Keeps the result inside the working space's representable range.
  ///
  /// A Poisson solve is unbounded by construction: source gradients steeper
  /// than the destination's boundary can admit will overshoot, and alpha in
  /// particular has to stay in `0...1` or the patch composites as nonsense. A
  /// value that has gone non-finite falls back to the destination, which is
  /// always a defensible pixel.
  private static func clamp(_ values: inout [Float], destination: [Float]) {
    for index in 0..<values.count {
      let value = values[index]
      guard value.isFinite else {
        values[index] = destination[index].isFinite ? destination[index] : 0
        continue
      }
      // The same bounds `LinearRGBAColor` validates against, with alpha — the
      // fourth channel — held to unit coverage.
      if index % channels == channels - 1 {
        values[index] = min(max(value, 0), 1)
      } else {
        values[index] = min(max(value, -0.5), 16)
      }
    }
  }
}
