import SwiftUI

/// A side panel: a stack of collapsible sections, and nothing else.
///
/// The host stays deliberately thin. It knows how to lay sections out and how
/// to collapse them; every section's content, state and actions belong to the
/// feature that installed it. Both the left panel and the assistance panel are
/// instances of this, differing only in what was installed into them.
struct PanelView: View {
  @ObservedObject var model: PanelModel
  /// What this particular panel would hold, for when it holds nothing yet.
  let emptyDescription: String

  var body: some View {
    Group {
      if model.sections.isEmpty {
        ContentUnavailableView(
          "Nothing to Show",
          systemImage: "sidebar.left",
          description: Text(emptyDescription)
        )
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.sections) { section in
              PanelSectionView(section: section)
              Divider()
            }
          }
          .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

private struct PanelSectionView: View {
  let section: PanelSection

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias ExpandedState = SwiftUI.State<Bool>
  @ExpandedState private var isExpanded: Bool

  init(section: PanelSection) {
    self.section = section
    _isExpanded = ExpandedState(initialValue: section.startsExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PanelDisclosureHeader(
        title: section.title,
        systemImage: section.systemImage,
        isExpanded: isExpanded
      ) {
        withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
      }

      if isExpanded {
        section.content
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

/// The shared disclosure header for panel sections. Keeping the header in one
/// place gives purpose-built panels the same chevron, icon, spacing and
/// accessibility behavior as sections hosted by `PanelView`.
struct PanelDisclosureHeader: View {
  let title: String
  let systemImage: String?
  let isExpanded: Bool
  var helpText: String?
  let toggle: () -> Void

  init(
    title: String,
    systemImage: String? = nil,
    isExpanded: Bool,
    helpText: String? = nil,
    toggle: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isExpanded = isExpanded
    self.helpText = helpText
    self.toggle = toggle
  }

  var body: some View {
    Group {
      if let helpText {
        button.help(helpText)
      } else {
        button
      }
    }
    // A panel header keeps one typographic scale even when it is embedded in
    // compact inspector content. Without this override, the right panel's
    // small control environment shrinks the label and its section icon.
    .controlSize(.regular)
  }

  private var button: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
        if let systemImage {
          Image(systemName: systemImage)
            .font(.body)
            .foregroundStyle(.secondary)
        }
        Text(title)
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityAddTraits(.isHeader)
  }
}
