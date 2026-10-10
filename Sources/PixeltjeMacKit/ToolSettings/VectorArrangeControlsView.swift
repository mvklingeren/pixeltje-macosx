import PixeltjeMacDomain
import SwiftUI

/// Align, distribute, reflect, order, and re-home the selected vector objects.
///
/// These sit in the left tool settings so they are reachable while a selection
/// is being manipulated, rather than requiring a trip to a menu mid-gesture.
/// The same commands have menu items, for keyboard access and discoverability.
struct VectorArrangeControlsView: View {
  let selectionCount: Int
  let isLocked: Bool
  /// The fill rule the selection's compound paths share, when it has any.
  let selectedCompoundFillRule: VectorFillRule?
  let send: (VectorArrangeCommand) -> Void

  private typealias ReferenceState = SwiftUI.AppStorage<String>
  @ReferenceState("VectorAlignmentReference") private var storedReference =
    VectorAlignmentReference.selection.rawValue

  private var reference: VectorAlignmentReference {
    VectorAlignmentReference(rawValue: storedReference) ?? .selection
  }

  /// Aligning one object to itself does nothing, so a single selection lines up
  /// against the canvas whatever the picker says. The picker still shows the
  /// stored choice, which is what a second object will use.
  private var effectiveReference: VectorAlignmentReference {
    selectionCount <= 1 ? .canvas : reference
  }

  private var isEnabled: Bool { selectionCount > 0 && !isLocked }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Arrange").font(.subheadline).bold()
        Spacer()
        Text(summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Picker("Align to", selection: referenceBinding) {
        ForEach(VectorAlignmentReference.allCases, id: \.self) { value in
          Text(value.label).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Align to")
      .disabled(selectionCount <= 1)

      alignmentRow(VectorAlignment.allCases.filter(\.isHorizontal))
      alignmentRow(VectorAlignment.allCases.filter { !$0.isHorizontal })

      HStack(spacing: 6) {
        ForEach(VectorDistributionAxis.allCases, id: \.self) { axis in
          command(axis.label, systemImage: axis.symbolName, .distribute(axis))
            // Two objects are already as evenly spaced as they can be.
            .disabled(!isEnabled || selectionCount < 3)
        }
        Divider().frame(height: 16)
        command("Reflect Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", .reflect(horizontally: true))
        command("Reflect Vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down", .reflect(horizontally: false))
        Spacer()
      }

      HStack(spacing: 6) {
        ForEach(VectorOrderPlacement.allCases, id: \.self) { placement in
          command(placement.actionName, systemImage: orderSymbol(placement), .order(placement))
        }
        Spacer()
      }

      Divider()

      Text("Combine").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach(VectorBooleanOperation.allCases, id: \.self) { operation in
          command(operation.label, systemImage: operation.symbolName, .boolean(operation))
            // A Boolean needs something to combine with.
            .disabled(!isEnabled || selectionCount < 2)
            .help(operation.help)
        }
        Spacer()
      }

      if let rule = selectedCompoundFillRule {
        Picker("Fill rule", selection: fillRuleBinding(rule)) {
          ForEach(VectorFillRule.allCases, id: \.self) { value in
            Text(value.label).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Compound path fill rule")
        .disabled(!isEnabled)
        Button("Release Compound Path") { send(.releaseCompoundPath) }
          .controlSize(.small)
          .disabled(!isEnabled)
          .help("Splits the compound path back into ordinary paths.")
      }

      Divider()

      HStack(spacing: 6) {
        Button("Duplicate in Place") { send(.duplicateInPlace) }
        Button("To New Layer") { send(.moveToNewLayer) }
          .help("Moves the selected objects onto a new vector layer above this one.")
        Spacer()
      }
      .controlSize(.small)
      .disabled(!isEnabled)
    }
  }

  private var summary: String {
    switch selectionCount {
    case 0: "No objects selected"
    case 1: "1 object"
    default: "\(selectionCount) objects"
    }
  }

  private func fillRuleBinding(_ current: VectorFillRule) -> Binding<VectorFillRule> {
    Binding(get: { current }, set: { send(.setFillRule($0)) })
  }

  private var referenceBinding: Binding<VectorAlignmentReference> {
    Binding(get: { reference }, set: { storedReference = $0.rawValue })
  }

  private func alignmentRow(_ alignments: [VectorAlignment]) -> some View {
    HStack(spacing: 6) {
      ForEach(alignments, id: \.self) { alignment in
        command(
          alignment.label,
          systemImage: alignment.symbolName,
          .align(alignment, effectiveReference))
      }
      Spacer()
    }
  }

  private func command(
    _ title: String, systemImage: String, _ command: VectorArrangeCommand
  ) -> some View {
    Button {
      send(command)
    } label: {
      Image(systemName: systemImage)
        .frame(width: 16)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help(title)
    .accessibilityLabel(title)
    .disabled(!isEnabled)
  }

  private func orderSymbol(_ placement: VectorOrderPlacement) -> String {
    switch placement {
    case .front: "square.3.layers.3d.top.filled"
    case .forward: "arrow.up"
    case .backward: "arrow.down"
    case .back: "square.3.layers.3d.bottom.filled"
    }
  }
}
