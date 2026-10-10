import SwiftUI

/// The distribution of the frame on screen, at the top of the right panel.
///
/// It reads `EditorModel.histogram`, which arrives after its rendered frame and
/// is accepted only while that exact revision remains on the canvas. The view
/// never measures anything itself.
///
/// The two triangles are the clipping indicators. They are display state, so
/// pressing one repaints the canvas overlay without touching the recipe, the
/// undo stack, or the document's dirty flag.
struct HistogramView: View {
  @ObservedObject var model: EditorModel
  let send: (InspectorIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      plot
        .frame(height: 92)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12))
        )
      controls
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
  }

  private var controls: some View {
    HStack(spacing: 6) {
      clippingButton(
        edge: .shadows,
        isOn: model.clipping.shadows,
        color: .blue,
        title: "Shadows",
        fraction: model.histogram?.shadowFraction
      )
      Spacer(minLength: 4)
      beforeButton
      Spacer(minLength: 4)
      clippingButton(
        edge: .highlights,
        isOn: model.clipping.highlights,
        color: .red,
        title: "Highlights",
        fraction: model.histogram?.highlightFraction
      )
    }
    .frame(maxWidth: .infinity)
    .font(.caption2)
    .monospacedDigit()
  }

  /// Before / After, beside the measurement of the frame it compares.
  ///
  /// A view toggle rather than a tool: it renders the captured RAW defaults
  /// down the same path, leaving the recipe and the dirty flag alone. It sat in
  /// the tool strip for a while behind a separator that existed only to explain
  /// why it was not a tool. Here it needs no explaining — it belongs with the
  /// histogram for the same reason the clipping triangles do, because both say
  /// something about the frame on screen rather than about the next gesture.
  private var beforeButton: some View {
    Button {
      send(.toggleBefore)
    } label: {
      Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
        .font(.caption)
        .foregroundStyle(model.isShowingBefore ? Color.accentColor : .secondary)
        .padding(3)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(model.isShowingBefore ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.canShowBefore)
    .help(
      model.canShowBefore
        ? "Before / After (\\) · shows the captured RAW defaults without changing the document"
        : "There are no captured RAW defaults to compare against."
    )
    .accessibilityLabel("Before and after")
    .accessibilityValue(model.isShowingBefore ? "Showing before" : "Showing after")
  }

  @ViewBuilder
  private var plot: some View {
    if let histogram = model.histogram, histogram.sampleCount > 0 {
      Canvas { context, size in
        let ceiling = max(histogram.displayCeiling, 1)

        // Additive light: where red, green and blue overlap the plot goes
        // white, which is how a photographer reads a neutral image at a glance.
        context.blendMode = .screen
        fill(context, histogram.red, ceiling: ceiling, size: size, color: .red)
        fill(context, histogram.green, ceiling: ceiling, size: size, color: .green)
        fill(context, histogram.blue, ceiling: ceiling, size: size, color: .blue)

        // Luminance rides on top as an outline so it stays readable over the
        // three filled channels instead of being swallowed by them.
        context.blendMode = .normal
        context.stroke(
          path(histogram.luminance, ceiling: ceiling, size: size, closed: false),
          with: .color(.white.opacity(0.85)),
          lineWidth: 1
        )
      }
      .accessibilityLabel("Histogram")
      .accessibilityValue(accessibilitySummary(histogram))
    } else {
      Text(histogramPlaceholder)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var histogramPlaceholder: String {
    if model.isAnalyzingRenderedFrame { return "Measuring…" }
    if model.renderedFrame == nil && model.renderStatus.isBusy { return "Rendering…" }
    if model.renderedFrame != nil { return "Histogram unavailable" }
    return "No rendered image"
  }

  private func clippingButton(
    edge: ClippingEdge,
    isOn: Bool,
    color: Color,
    title: String,
    fraction: Double?
  ) -> some View {
    Button {
      var next = model.clipping
      switch edge {
      case .shadows: next.shadows.toggle()
      case .highlights: next.highlights.toggle()
      }
      send(.setClipping(next))
    } label: {
      HStack(spacing: 4) {
        if edge == .shadows {
          clippingTriangle(edge: edge, isOn: isOn, color: color)
        }
        Text(fraction.map { "\(title) \(percentage($0))" } ?? "\(title) —")
          .lineLimit(1)
        if edge == .highlights {
          clippingTriangle(edge: edge, isOn: isOn, color: color)
        }
      }
      .foregroundStyle(isOn ? color : .secondary)
      .padding(.horizontal, 4)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(isOn ? color.opacity(0.18) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Toggle \(title.lowercased()) clipping")
    .accessibilityLabel("\(title) clipping")
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityHint(
      fraction.map { "\(percentage($0)) of pixels clipped" } ?? "No measurement yet"
    )
  }

  private func clippingTriangle(edge: ClippingEdge, isOn: Bool, color: Color) -> some View {
    ClippingTriangle(pointsLeft: edge == .shadows)
      .fill(isOn ? color : Color.secondary.opacity(0.45))
      .frame(width: 11, height: 12)
  }

  private enum ClippingEdge {
    case shadows
    case highlights
  }

  private func percentage(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(fraction < 0.01 ? 2 : 1)))
  }

  private func accessibilitySummary(_ histogram: ImageHistogram) -> String {
    "\(percentage(histogram.shadowFraction)) clipped shadows, "
      + "\(percentage(histogram.highlightFraction)) clipped highlights"
  }

  /// `GraphicsContext` is a value type and `fill` does not mutate it, so the
  /// blend mode set by the caller travels with the copy.
  private func fill(
    _ context: GraphicsContext,
    _ bins: [Int],
    ceiling: Int,
    size: CGSize,
    color: Color
  ) {
    context.fill(
      path(bins, ceiling: ceiling, size: size, closed: true),
      with: .color(color.opacity(0.72))
    )
  }

  /// One channel as a path across the full width, sampled per bin.
  ///
  /// Bins above the ceiling are flattened against the top edge rather than
  /// rescaling the whole plot, so one spike cannot squash everything else.
  private func path(_ bins: [Int], ceiling: Int, size: CGSize, closed: Bool) -> Path {
    var path = Path()
    guard bins.count > 1, size.width > 0, size.height > 0 else { return path }
    let step = size.width / CGFloat(bins.count - 1)
    for (index, count) in bins.enumerated() {
      let height = min(CGFloat(count) / CGFloat(ceiling), 1) * size.height
      let point = CGPoint(x: CGFloat(index) * step, y: size.height - height)
      if index == 0 {
        if closed { path.move(to: CGPoint(x: 0, y: size.height)) }
        if closed { path.addLine(to: point) } else { path.move(to: point) }
      } else {
        path.addLine(to: point)
      }
    }
    if closed {
      path.addLine(to: CGPoint(x: size.width, y: size.height))
      path.closeSubpath()
    }
    return path
  }
}

/// The small triangle that arms one end of the histogram, pointing at the end
/// of the plot it marks.
private struct ClippingTriangle: Shape {
  let pointsLeft: Bool

  func path(in rect: CGRect) -> Path {
    var path = Path()
    if pointsLeft {
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
    } else {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    }
    path.closeSubpath()
    return path
  }
}
