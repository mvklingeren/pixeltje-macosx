import AppKit
import PixeltjeMacDomain
import SwiftUI

struct LayersInspectorView: View {
  @ObservedObject var model: EditorModel
  let send: (InspectorIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias CollapsedState = SwiftUI.State<Set<ProjectLayerID>>
  /// Groups the user has folded shut. Collapsing is a view concern: it changes
  /// nothing in the recipe and is not undoable.
  @CollapsedState private var collapsedGroupIDs: Set<ProjectLayerID> = []
  @AppStorage(AppSettings.allowsMultipleRawLayersKey) private var allowsMultipleRawLayers = false

  var body: some View {
    if layerStack.contentLayers.isEmpty && model.recipe.source != nil {
      ContentUnavailableView(
        "No Layers",
        systemImage: "square.3.layers.3d",
        description: Text("Open a RAW image to create its background layer.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(24)
    } else {
      VStack(spacing: 0) {
        layerList
        Divider()
        details
      }
    }
  }

  private var layerList: some View {
    VStack(spacing: 0) {
      List(visibleEntries, selection: layerSelection) { entry in
        LayerRow(
          entry: entry,
          isCollapsed: collapsedGroupIDs.contains(entry.id),
          isPrimary: model.selectedLayerIDs.count > 1 && layerStack.activeLayerID == entry.id,
          isPixelTarget: model.resolvedPaintTarget == .layerPixels(entry.id),
          isMaskTarget: {
            guard let mask = entry.layer.layerMask else { return false }
            return model.resolvedPaintTarget == .layerMask(entry.id, mask.id)
          }(),
          toggleEnabled: {
            send(
              .change(
                .setLayerEnabled(entry.id, !entry.layer.isEnabled),
                interactive: false
              ))
          },
          toggleCollapsed: { toggleCollapsed(entry.id) },
          selectPixels: { selectPixels(of: entry.id) },
          selectMask: { maskID in selectMask(maskID, on: entry.id) }
        )
        .tag(entry.id)
      }
      .listStyle(.inset)
      .frame(minHeight: 112, idealHeight: 180, maxHeight: 208)
      .accessibilityLabel("Document layers")

      Divider()

      commands
    }
  }

  /// The bar under the layer list, in one row.
  ///
  /// It reads left to right the way the work goes: what to add, then what to
  /// do with the selected layer. Every kind of new layer shares the Add menu
  /// rather than taking a button of its own, so the bar stays one row at the
  /// panel's narrowest width. Reordering stays two plain buttons, because it is
  /// the one command that is clicked several times in a row.
  private var commands: some View {
    HStack(spacing: 2) {
      Menu {
        Button(action: addPaintLayer) {
          Label("Paint Layer", systemImage: "paintbrush.pointed")
        }
        Button(action: addGroupLayer) {
          Label("Empty Group", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
          send(.addImage)
        } label: {
          Label("Place Image…", systemImage: "photo.badge.plus")
        }
        if allowsMultipleRawLayers {
          Button {
            send(.addRaw)
          } label: {
            Label("Place RAW…", systemImage: "camera.badge.ellipsis")
          }
        }
      } label: {
        commandLabel("Add Layer", systemImage: "plus")
      }
      .fixedSize()
      .help("Add a paint layer or group above the selection, or place a file as a linked layer")

      Menu {
        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
          Button(kind.label) { addAdjustmentLayer(kind) }
        }
      } label: {
        commandLabel("Add Adjustment Layer", systemImage: "circle.lefthalf.filled")
      }
      .fixedSize()
      .help("Add an adjustment layer that changes everything below it in its group")

      Menu {
        Button("Reveal All (White)") { addLayerMask(revealsLayer: true) }
        Button("Hide All (Black)") { addLayerMask(revealsLayer: false) }
      } label: {
        commandLabel("Add Layer Mask", systemImage: "rectangle.badge.plus")
      }
      .fixedSize()
      .help("Add a paintable white or black layer mask")
      .disabled(!canAddLayerMask)

      Spacer(minLength: 8)

      Menu {
        Button("Group Selected Layer") { groupSelectedLayer() }
        Button("Ungroup") { ungroupSelectedLayer() }
          .disabled(selectedLayer?.isGroupLayer != true)
        Divider()
        Button("Move Out of Group") { moveSelectionToGroup(nil) }
          .disabled(!canMoveOutOfGroup)
        ForEach(destinationGroups, id: \.id) { group in
          Button("Move into \(group.name)") { moveSelectionToGroup(group.id) }
        }
      } label: {
        commandLabel("Grouping", systemImage: "folder")
      }
      .fixedSize()
      .help("Group, ungroup, and move the selected layer between groups")
      .disabled(!canEditSelection)

      Button {
        moveSelectedLayer(.up)
      } label: {
        commandLabel("Move Layer Up", systemImage: "arrow.up")
      }
      .help("Move the selected layer up among its siblings")
      .disabled(!canMoveUp)

      Button {
        moveSelectedLayer(.down)
      } label: {
        commandLabel("Move Layer Down", systemImage: "arrow.down")
      }
      .help("Move the selected layer down among its siblings")
      .disabled(!canMoveDown)

      Button(action: duplicateSelectedLayer) {
        commandLabel("Duplicate", systemImage: "plus.square.on.square")
      }
      .help("Duplicate the selected layer")
      .disabled(!canDuplicateSelection)

      Button(action: deleteSelectedLayer) {
        commandLabel("Delete Layer", systemImage: "trash")
      }
      .help("Delete the selected layer")
      .disabled(!canEditSelection)
    }
    .buttonStyle(.borderless)
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
  }

  /// An icon-only command label with a hit target that does not need aiming.
  private func commandLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .labelStyle(.iconOnly)
      .frame(width: 24, height: 22)
      .contentShape(Rectangle())
  }

  /// The selected layer's sections, most used first: what the layer is, how it
  /// blends, its own content, and last the masks that hide parts of it.
  private var details: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if model.selectedLayerIDs.count > 1 {
          multiSelectionDetails
        } else if let layer = selectedLayer {
          SelectedLayerHeader(layer: layer)

          if !layer.isCanvasLayer {
            CompositingInspectorView(
              layer: layer,
              selection: model.recipe.selection,
              isPreviewing: model.differencePreviewLayerID == layer.id,
              send: send)
          }

          switch layer.content {
          case .developedRaw, .group, .raster, .paint:
            EmptyView()
          case .generatedInpaint(let inpaint):
            InpaintResultInspectorView(layer: layer, inpaint: inpaint, send: send)
          case .image(let image):
            ImageLayerInspectorView(image: image)
          case .canvas(let canvas):
            CanvasLayerInspectorView(
              canvas: canvas,
              settings: model.recipe.canvasSettings,
              isEditable: model.recipe.source == nil,
              viewSettings: CanvasViewSettings.shared,
              send: send
            )
          case .vector(let vectorLayer):
            VStack(alignment: .leading, spacing: 4) {
              layerOperationButton(for: layer)
            }
            VectorObjectListView(
              layerID: layer.id,
              vector: vectorLayer,
              isLocked: layer.isLocked,
              // Object selection belongs to the active layer, so a layer that
              // is merely visible in the list shows none.
              selectedObjectIDs: model.recipe.layerStack.activeLayerID == layer.id
                ? model.selectedVectorObjectIDs : [],
              send: send
            )
            VectorShapeInspectorView(
              layerID: layer.id,
              vector: vectorLayer,
              isLocked: layer.isLocked,
              selectedObjectIDs: model.recipe.layerStack.activeLayerID == layer.id
                ? model.selectedVectorObjectIDs : [],
              canvasWidth: Double(layerStack.canvas.width),
              canvasHeight: Double(layerStack.canvas.height),
              send: send
            )
          case .text(let text):
            TextLayerSummaryView(text: text)
          case .adjustment(let adjustment):
            AdjustmentLayerInspectorView(
              layerID: layer.id,
              adjustment: adjustment,
              affectedCount: layerStack.layersAffected(by: layer.id).count,
              send: send
            )
          }

          // The layer mask and the mask list sit together under the layer they
          // belong to. Masks are part of the layer, so they are shown with it
          // rather than at document level.
          if !layer.isCanvasLayer {
            LayerMaskInspectorView(
              layer: layer,
              isTarget: layer.layerMask.map {
                model.resolvedPaintTarget == .layerMask(layer.id, $0.id)
              } ?? false,
              send: send
            )
            MaskListInspectorView(
              layer: layer,
              activeMaskID: model.maskTool.activeLayerID == layer.id
                ? model.maskTool.activeMaskID : nil,
              send: { send(.mask($0)) }
            )
          }
        }
      }
      // One control density for every section, so the panel reads as one
      // inspector rather than a stack of differently sized forms.
      .controlSize(.small)
      .padding(12)
    }
  }

  // MARK: - Stack reading

  private var layerStack: LayerStackRecipe {
    model.recipe.layerStack
  }

  private var entries: [LayerStackEntry] {
    layerStack.flattenedLayers
  }

  /// The rows the list shows: everything except what a collapsed group hides.
  private var visibleEntries: [LayerStackEntry] {
    guard !collapsedGroupIDs.isEmpty else { return entries }
    return entries.filter { entry in
      !entry.ancestorIDs.contains(where: collapsedGroupIDs.contains)
    }
  }

  private var layerSelection: Binding<Set<ProjectLayerID>> {
    Binding(
      get: { model.selectedLayerIDs },
      set: { send(.selectLayers($0)) }
    )
  }

  private var selectedLayerID: ProjectLayerID? {
    guard model.selectedLayerIDs.count == 1 else { return nil }
    return model.selectedLayerIDs.first
  }

  private var selectedLayer: ProjectLayer? {
    selectedLayerID.flatMap { layerStack.layer(id: $0) }
  }

  /// Whether the selection is a real content layer rather than the canvas.
  private var canEditSelection: Bool {
    guard let layer = selectedLayer else { return false }
    return !layer.isCanvasLayer
  }

  /// Copying a RAW, directly or through a group, is another way to create a RAW
  /// layer and therefore observes the same advanced opt-in as Add RAW.
  private var canDuplicateSelection: Bool {
    guard let selectedLayer, canEditSelection else { return false }
    return allowsMultipleRawLayers || !selectedLayer.containsDevelopedRaw
  }

  private var canAddLayerMask: Bool {
    canEditSelection && selectedLayer?.layerMask == nil
  }

  private var canMoveUp: Bool {
    canMove(.up)
  }

  private var canMoveDown: Bool {
    canMove(.down)
  }

  /// Asks the recipe itself whether the move would change anything, so the
  /// button state can never disagree with what the mutation does.
  private func canMove(_ direction: LayerMoveDirection) -> Bool {
    guard let selectedLayerID, canEditSelection else { return false }
    return layerStack.moving(selectedLayerID, direction) != layerStack
  }

  private var canMoveOutOfGroup: Bool {
    guard let selectedLayerID, canEditSelection else { return false }
    return layerStack.parentID(of: selectedLayerID) != nil
  }

  /// The groups the selected layer can move into: every group that is not the
  /// layer itself, not inside it, and not already its parent.
  private var destinationGroups: [ProjectLayer] {
    guard let selectedLayerID, canEditSelection else { return [] }
    let parentID = layerStack.parentID(of: selectedLayerID)
    return layerStack.groupLayers.filter { group in
      group.id != parentID && !layerStack.layer(group.id, isWithin: selectedLayerID)
    }
  }

  // MARK: - Selection

  private func selectPixels(of layerID: ProjectLayerID) {
    send(.selectLayers([layerID]))
    send(.setPaintTarget(.layerPixels(layerID)))
  }

  private func selectMask(_ maskID: MaskID, on layerID: ProjectLayerID) {
    send(.selectLayers([layerID]))
    send(.setPaintTarget(.layerMask(layerID, maskID)))
  }

  private func toggleCollapsed(_ id: ProjectLayerID) {
    if collapsedGroupIDs.contains(id) {
      collapsedGroupIDs.remove(id)
    } else {
      collapsedGroupIDs.insert(id)
    }
  }

  // MARK: - Commands

  private func addPaintLayer() {
    let layer = ProjectLayer.paint()
    send(.change(.addLayer(layer), interactive: false))
    send(.setPaintTarget(.layerPixels(layer.id)))
    select(layer.id)
  }

  private func addGroupLayer() {
    let layer = ProjectLayer.group()
    send(.change(.addLayer(layer), interactive: false))
    select(layer.id)
  }

  private func addLayerMask(revealsLayer: Bool) {
    guard let selectedLayerID, canAddLayerMask else { return }
    let mask = MaskRecipe.layerMask(revealsLayer: revealsLayer)
    send(.change(.setLayerMask(selectedLayerID, mask), interactive: false))
    send(.setPaintTarget(.layerMask(selectedLayerID, mask.id)))
  }

  private func addAdjustmentLayer(_ kind: AdjustmentKind) {
    let layer = ProjectLayer.adjustment(kind.defaultRecipe)
    send(.change(.addLayer(layer), interactive: false))
    select(layer.id)
  }

  private func duplicateSelectedLayer() {
    guard let selectedLayerID, canDuplicateSelection else { return }
    let duplicateID = ProjectLayerID()
    send(.change(.duplicateLayer(selectedLayerID, duplicateID: duplicateID), interactive: false))
    select(duplicateID)
  }

  private func deleteSelectedLayer() {
    guard let selectedLayerID else { return }
    send(.change(.removeLayer(selectedLayerID), interactive: false))
  }

  private func moveSelectedLayer(_ direction: LayerMoveDirection) {
    guard let selectedLayerID else { return }
    send(.change(.moveLayer(selectedLayerID, direction), interactive: false))
  }

  private func groupSelectedLayer() {
    guard let selectedLayerID else { return }
    let groupID = ProjectLayerID()
    send(.change(.groupLayer(selectedLayerID, groupID: groupID), interactive: false))
    select(groupID)
  }

  private func ungroupSelectedLayer() {
    guard let selectedLayerID, selectedLayer?.isGroupLayer == true else { return }
    collapsedGroupIDs.remove(selectedLayerID)
    send(.change(.ungroupLayer(selectedLayerID), interactive: false))
  }

  private func moveSelectionToGroup(_ groupID: ProjectLayerID?) {
    guard let selectedLayerID else { return }
    if let groupID {
      collapsedGroupIDs.remove(groupID)
    }
    send(.change(.moveLayerToGroup(selectedLayerID, groupID: groupID), interactive: false))
  }

  /// Selects a layer the document has just created, after the recipe change
  /// has been published.
  private func select(_ id: ProjectLayerID) {
    send(.selectLayers([id]))
  }

  @ViewBuilder
  private var multiSelectionDetails: some View {
    let count = model.selectedLayerIDs.count
    VStack(alignment: .leading, spacing: 10) {
      InspectorHeader(
        symbolName: "square.3.layers.3d",
        title: "\(count) Layers Selected",
        subtitle: "The first-selected layer stays primary for tools."
      )

      switch model.layerOperationStatus {
      case .merging:
        HStack {
          ProgressView().controlSize(.small)
          Text("Merging layers…")
          Spacer()
          Button("Cancel") { send(.cancelLayerOperation) }
        }
      case .rasterizing:
        ProgressView("Rasterizing layer…")
      case .copying:
        ProgressView("Copying selection…")
      case .pasting:
        ProgressView("Pasting image…")
      case .healing:
        ProgressView("Healing…")
      case .idle, .failed:
        Button("Merge \(count) Layers") {
          send(.mergeLayers(model.selectedLayerIDs))
        }
        .buttonStyle(.borderedProminent)
        .disabled(mergePlan == nil)
        if mergePlan == nil {
          Text(mergeUnavailableReason)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      if case .failed(let message) = model.layerOperationStatus {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var mergePlan: LayerMergePlan? {
    guard layerStack.canvas.isResolved else { return nil }
    return layerStack.mergePlan(for: model.selectedLayerIDs)
  }

  private var mergeUnavailableReason: String {
    if !layerStack.canvas.isResolved { return "Set the canvas size before merging layers." }
    return "Choose adjacent, enabled, unlocked layers in the same group using Normal blend mode."
  }

  @ViewBuilder
  private func layerOperationButton(for layer: ProjectLayer) -> some View {
    switch model.layerOperationStatus {
    case .rasterizing:
      HStack {
        ProgressView().controlSize(.small)
        Text("Rasterizing layer…")
        Spacer()
        Button("Cancel") { send(.cancelLayerOperation) }
      }
    case .merging:
      ProgressView("Merging layers…")
    case .copying:
      ProgressView("Copying selection…")
    case .pasting:
      ProgressView("Pasting image…")
    case .healing:
      ProgressView("Healing…")
    case .idle, .failed:
      Button("Rasterize Layer") { send(.rasterizeLayer(layer.id)) }
        .disabled(!canRasterize(layer))
      if !layerStack.canvas.isResolved {
        Text("Set the canvas size before rasterizing this layer.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if layer.isLocked {
        Text("Unlock this layer before rasterizing it.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if !canRasterize(layer) {
        Text(
          "Vector masks, transforms, and non-Normal blending must be resolved before rasterizing."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    if case .failed(let message) = model.layerOperationStatus {
      Text(message)
        .font(.caption2)
        .foregroundStyle(.red)
    }
  }

  private func canRasterize(_ layer: ProjectLayer) -> Bool {
    layerStack.canvas.isResolved && layer.isVectorLayer && !layer.isLocked
      && layer.compositing.blendMode == .normal && layer.masks.isEmpty
      && layer.layerMask == nil && layer.transform == nil
  }
}

private struct LayerRow: View {
  let entry: LayerStackEntry
  let isCollapsed: Bool
  let isPrimary: Bool
  let isPixelTarget: Bool
  let isMaskTarget: Bool
  let toggleEnabled: () -> Void
  let toggleCollapsed: () -> Void
  let selectPixels: () -> Void
  let selectMask: (MaskID) -> Void

  private var layer: ProjectLayer { entry.layer }

  var body: some View {
    HStack(spacing: 8) {
      leadingControls
      HStack(spacing: 4) {
        Button(action: selectPixels) {
          ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(.quaternary)
            Image(systemName: layer.symbolName)
              .foregroundStyle(.secondary)
          }
          .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(isPixelTarget ? Color.accentColor : .clear, lineWidth: 2)
          )
          .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .help("Paint layer pixels")

        if let mask = layer.layerMask {
          Button { selectMask(mask.id) } label: {
            ZStack {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(mask.strokeSurface?.initialCoverage == 0 ? Color.black : Color.white)
              Image(systemName: "paintbrush.pointed")
                .font(.caption2)
                .foregroundStyle(mask.strokeSurface?.initialCoverage == 0 ? .white : .black)
            }
            .overlay(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isMaskTarget ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isMaskTarget ? 2 : 1)
            )
            .frame(width: 34, height: 34)
          }
          .buttonStyle(.plain)
          .help("Paint layer-mask coverage")
          .accessibilityLabel("Layer mask thumbnail")
        }
      }
      .fixedSize(horizontal: true, vertical: false)

      VStack(alignment: .leading, spacing: 2) {
        Text(layer.name)
          .lineLimit(1)
        Text(layer.rowDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .opacity(entry.isEffectivelyEnabled ? 1 : 0.55)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(layer.name)
      .accessibilityValue(
        layer.isEnabled
          ? "Enabled, \(layer.contentDescription)"
          : "Disabled, \(layer.contentDescription)"
      )

      if isPrimary {
        Image(systemName: "scope")
          .font(.caption)
          .foregroundStyle(.tint)
          .help("Primary layer")
          .accessibilityLabel("Primary layer")
      }

      Text(layer.badge)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 2)
  }

  private var leadingControls: some View {
    HStack(spacing: 8) {
      if entry.depth > 0 {
        Color.clear.frame(width: CGFloat(entry.depth) * 14, height: 28)
          .accessibilityHidden(true)
      }

      if layer.isGroupLayer {
        Button(action: toggleCollapsed) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption2)
            .frame(width: 12, height: 28)
        }
        .buttonStyle(.borderless)
        .help(isCollapsed ? "Expand group" : "Collapse group")
        .accessibilityLabel(isCollapsed ? "Expand \(layer.name)" : "Collapse \(layer.name)")
      } else {
        Color.clear.frame(width: 12, height: 28)
          .accessibilityHidden(true)
      }

      if layer.isCanvasLayer {
        // The canvas has no pixels to show or hide; keep the row aligned.
        Color.clear.frame(width: 18, height: 28)
      } else {
        Button(action: toggleEnabled) {
          Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
            .frame(width: 18, height: 28)
        }
        .buttonStyle(.borderless)
        .help(layer.isEnabled ? "Disable layer" : "Enable layer")
        .accessibilityLabel(layer.isEnabled ? "Disable \(layer.name)" : "Enable \(layer.name)")
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

extension ProjectLayer {
  /// A group duplicates all of its descendants, so its RAW content must obey
  /// the same multiple-RAW opt-in as a directly selected RAW layer.
  fileprivate var containsDevelopedRaw: Bool {
    switch content {
    case .developedRaw:
      true
    case .group(let group):
      group.children.contains(where: \.containsDevelopedRaw)
    case .image, .raster, .generatedInpaint, .paint, .vector, .canvas, .text, .adjustment:
      false
    }
  }

  fileprivate var contentDescription: String {
    switch content {
    case .developedRaw: "Developed RAW"
    case .image: "Linked image"
    case .raster: "Project raster"
    case .generatedInpaint: "Generated inpaint"
    case .paint: "Paint"
    case .vector: "Vector artwork"
    case .canvas: "Document extent"
    case .text: "Text"
    case .group: "Group"
    case .adjustment(let adjustment): "\(adjustment.label) adjustment"
    }
  }

  fileprivate var rowDescription: String {
    switch content {
    case .developedRaw: "Developed RAW"
    case .image(let image): image.naturalSizeDescription
    case .raster(let raster): raster.naturalSizeDescription
    case .generatedInpaint(let inpaint): inpaint.naturalSizeDescription
    case .paint(let paint):
      paint.surface.strokes.count == 1
        ? "1 stroke" : "\(paint.surface.strokes.count) strokes"
    case .vector(let vectorLayer):
      vectorLayer.objects.count == 1
        ? "1 object" : "\(vectorLayer.objects.count) objects"
    case .canvas(let canvas):
      canvas.isResolved ? "\(canvas.width) × \(canvas.height) px" : "Size not set"
    case .text(let text):
      "\(Int(text.fontSize.rounded())) pt \(text.fontName)"
    case .group(let group):
      group.children.count == 1 ? "1 layer" : "\(group.children.count) layers"
    case .adjustment(let adjustment): adjustment.summary
    }
  }

  fileprivate var symbolName: String {
    switch content {
    case .developedRaw: "photo"
    case .image: "photo.on.rectangle"
    case .raster: "square.grid.3x3"
    case .generatedInpaint: "sparkles.rectangle.stack"
    case .paint: "paintbrush.pointed"
    case .vector: "point.3.connected.trianglepath.dotted"
    case .canvas: "rectangle.dashed"
    case .text: "textformat"
    case .group: "folder"
    case .adjustment: "circle.lefthalf.filled"
    }
  }

  fileprivate var badge: String {
    switch content {
    case .developedRaw: "RAW"
    case .image: "IMAGE"
    case .raster: "RASTER"
    case .generatedInpaint: "INPAINT"
    case .paint: "PAINT"
    case .vector: "VECTOR"
    case .canvas: "CANVAS"
    case .text: "TEXT"
    case .group: "GROUP"
    case .adjustment: "ADJUST"
    }
  }
}

extension AdjustmentRecipe {
  fileprivate var summary: String {
    switch self {
    case .exposure(let ev):
      "\(ev.formatted(.number.precision(.fractionLength(2)))) EV"
    case .colorControls(let brightness, let contrast, let saturation):
      "B \(brightness.formatted(.number.precision(.fractionLength(2))))"
        + " · C \(contrast.formatted(.number.precision(.fractionLength(2))))"
        + " · S \(saturation.formatted(.number.precision(.fractionLength(2))))"
    case .curves(let curve):
      curve.isNeutral ? "Neutral curve" : "Custom curve"
    case .levels(let levels):
      levels.isNeutral ? "Neutral levels" : "Custom levels"
    case .hueSaturation(let adjustment):
      adjustment.isNeutral ? "Neutral hue & saturation" : "Custom hue & saturation"
    case .blackAndWhite(let adjustment):
      adjustment.isNeutral ? "Neutral black & white" : "Black & white mix"
    case .colorLookup(let adjustment):
      adjustment.isNeutral ? "No lookup applied" : "\(adjustment.style.label) lookup"
    case .gradientMap(let adjustment):
      adjustment.isNeutral ? "No gradient applied" : "\(adjustment.style.label) gradient"
    case .invert:
      "Inverts everything below"
    }
  }
}

/// The singular mask that controls the selected layer's visibility. Its
/// thumbnail is the target selector; these controls change the saved recipe.
private struct LayerMaskInspectorView: View {
  let layer: ProjectLayer
  let isTarget: Bool
  let send: (InspectorIntent) -> Void

  var body: some View {
    RightPanelDisclosureSection(
      "Layer Mask",
      id: "layer-mask",
      systemImage: "rectangle.dashed"
    ) {
      if let mask = layer.layerMask {
        VStack(alignment: .leading, spacing: 8) {
          // Which surface the brush writes to, as one choice instead of a
          // status line and two target buttons.
          InspectorRow("Paint") {
            Picker(
              "Paint target",
              selection: Binding(
                get: { isTarget },
                set: { targetsMask in
                  send(
                    .setPaintTarget(
                      targetsMask ? .layerMask(layer.id, mask.id) : .layerPixels(layer.id)))
                }
              )
            ) {
              Text("Pixels").tag(false)
              Text("Mask").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(
              "Brush paints white coverage; Eraser paints black coverage. The active target is "
                + "outlined beside the layer thumbnail."
            )
          }

          HStack(spacing: 14) {
            Toggle(
              "Enabled",
              isOn: Binding(
                get: { mask.isEnabled },
                set: { send(.change(.setLayerMaskEnabled(layer.id, $0), interactive: false)) }
              )
            )
            Toggle(
              "Inverted",
              isOn: Binding(
                get: { mask.isInverted },
                set: { send(.change(.setLayerMaskInverted(layer.id, $0), interactive: false)) }
              )
            )
          }
          .toggleStyle(.checkbox)

          if let surface = mask.strokeSurface {
            Text(
              (surface.initialCoverage == 0 ? "Black base · hides all" : "White base · reveals all")
                + " · "
                + (surface.strokes.count == 1 ? "1 stroke" : "\(surface.strokes.count) strokes")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text("None")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Reveal All") { add(reveals: true) }
            Button("Hide All") { add(reveals: false) }
          }
          .help(
            "Add a white mask to reveal everything or a black mask to hide everything, then "
              + "select its thumbnail and use Brush or Eraser."
          )
          if layer.isImageLayer {
            Text(
              "The Eraser creates a white layer mask on its first stroke. The linked image stays untouched."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    } accessory: {
      if layer.layerMask != nil {
        Button(role: .destructive) {
          send(.change(.setLayerMask(layer.id, nil), interactive: false))
          send(.setPaintTarget(.layerPixels(layer.id)))
        } label: {
          Label("Delete Mask", systemImage: "trash")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Delete the layer mask")
      }
    }
  }

  private func add(reveals: Bool) {
    let mask = MaskRecipe.layerMask(revealsLayer: reveals)
    send(.change(.setLayerMask(layer.id, mask), interactive: false))
    send(.setPaintTarget(.layerMask(layer.id, mask.id)))
  }
}

/// Controls the saved local composite of a completed ComfyUI inpaint layer.
private struct InpaintResultInspectorView: View {
  let layer: ProjectLayer
  let inpaint: GeneratedInpaintLayerRecipe
  let send: (InspectorIntent) -> Void

  var body: some View {
    InspectorSection("Inpaint Result", id: "inpaint-result") {
      VStack(alignment: .leading, spacing: 8) {
        InspectorSlider(
          title: "Change threshold",
          value: inpaint.changeThreshold,
          range: 0...100,
          step: 1,
          format: .decimal(0),
          send: send,
          actionName: "Change Inpaint Threshold"
        ) { .setGeneratedInpaintThreshold(layer.id, $0) }
        .disabled(layer.isLocked)
        Text("Higher values restore more of the original image inside the selection. Zero keeps the full generated result.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Blend mode, opacity and fill of the selected layer.
///
/// Opacity and fill are separate recipe values even though nothing yet renders
/// between them, so a project saved today keeps the distinction when layer
/// styles arrive.
private struct CompositingInspectorView: View {
  let layer: ProjectLayer
  let selection: MaskRecipe?
  let isPreviewing: Bool
  let send: (InspectorIntent) -> Void

  var body: some View {
    RightPanelDisclosureSection(
      "Compositing",
      id: "compositing",
      systemImage: "circle.lefthalf.filled",
      helpText: layer.isGroupLayer
        ? "A group is composited on its own and then blended over the layers beneath it, so its "
          + "blend mode, opacity and fill apply to everything inside it at once."
        : nil
    ) {
      VStack(alignment: .leading, spacing: 6) {
        InspectorRow("Blend") {
          Picker(
            "Blend mode",
            selection: Binding(
              get: { layer.blendMode },
              set: { mode in
                if mode != .differenceKey && isPreviewing {
                  send(.setDifferencePreview(nil))
                }
                send(.change(.setLayerBlendMode(layer.id, mode), interactive: false))
              }
            )
          ) {
            ForEach(LayerBlendMode.allCases, id: \.self) { mode in
              Text(mode.label).tag(mode)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
        }

        if layer.blendMode == .differenceKey {
          Text("Show generated pixels around meaningful changes. Preview the matte to refine detection and its edges.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          HStack {
            Button(isPreviewing ? "Show Image" : "Preview Matte") {
              send(.setDifferencePreview(isPreviewing ? nil : layer.id))
            }
            Spacer()
          }

          InspectorRow("Reference") {
            Picker("Comparison image", selection: Binding(
              get: { layer.compositing.differenceReference },
              set: { reference in
                var options = layer.compositing
                options.differenceReference = reference
                send(.change(.setLayerDifferenceOptions(
                  layer.id, options, actionName: "Change Difference Reference"), interactive: false))
              }
            )) {
              Text(DifferenceKeyReference.currentBackdrop.label)
                .tag(DifferenceKeyReference.currentBackdrop)
              if layer.rasterLayer?.differenceSource != nil {
                Text(DifferenceKeyReference.generationInput.label)
                  .tag(DifferenceKeyReference.generationInput)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
          }

          InspectorSlider(
            title: "Cutoff",
            value: layer.differenceCutoff,
            range: 0...100,
            step: 0.5,
            format: .decimal(1),
            send: send,
            actionName: "Change Difference Cutoff"
          ) { .setLayerDifferenceCutoff(layer.id, $0) }

          InspectorSlider(
            title: "Softness (0 = Off)",
            value: layer.differenceSoftness,
            range: 0...50,
            step: 0.5,
            format: .decimal(1),
            send: send,
            actionName: "Change Difference Softness"
          ) { .setLayerDifferenceSoftness(layer.id, $0) }

          InspectorSlider(
            title: "Detection Scale (px)",
            value: layer.differenceRadius,
            range: 0...32,
            step: 1,
            format: .decimal(0),
            send: send,
            actionName: "Change Difference Detection Scale"
          ) { .setLayerDifferenceRadius(layer.id, $0) }

          InspectorSlider(
            title: "Fine Detail",
            value: layer.differenceFineDetail,
            range: 0...100,
            step: 1,
            format: .decimal(0),
            send: send,
            actionName: "Change Difference Fine Detail"
          ) { value in
            differenceOption("Change Difference Fine Detail") { $0.differenceFineDetail = value }
          }

          InspectorSlider(
            title: "Structure",
            value: layer.differenceStructure,
            range: 0...100,
            step: 1,
            format: .decimal(0),
            send: send,
            actionName: "Change Difference Structure"
          ) { value in
            differenceOption("Change Difference Structure") { $0.differenceStructure = value }
          }

          InspectorSlider(
            title: "Ignore Broad Drift",
            value: layer.differenceDrift,
            range: 0...100,
            step: 1,
            format: .decimal(0),
            send: send,
            actionName: "Change Difference Drift"
          ) { value in
            differenceOption("Change Difference Drift") { $0.differenceDrift = value }
          }

          InspectorSlider(
            title: "Expand / Contract (px)",
            value: layer.differenceGrow,
            range: -16...16,
            step: 0.5,
            format: .decimal(1),
            send: send,
            actionName: "Change Difference Edge"
          ) { value in
            differenceOption("Change Difference Edge") { $0.differenceGrow = value }
          }

          InspectorSlider(
            title: "Feather (px)",
            value: layer.differenceFeather,
            range: 0...16,
            step: 0.5,
            format: .decimal(1),
            send: send,
            actionName: "Change Difference Feather"
          ) { value in
            differenceOption("Change Difference Feather") { $0.differenceFeather = value }
          }

          Text("Paint or draw a selection, then use it to force the generated result into an area or preserve the original there.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Reveal Selection") {
              differenceSelection(reveal: true)
            }
            Button("Protect Selection") {
              differenceSelection(reveal: false)
            }
          }
          .disabled(selection == nil || layer.isLocked)
          if layer.compositing.differenceRevealMask != nil
            || layer.compositing.differenceProtectMask != nil {
            HStack {
              if layer.compositing.differenceRevealMask != nil {
                Button("Clear Reveal") { clearDifferenceSelection(reveal: true) }
              }
              if layer.compositing.differenceProtectMask != nil {
                Button("Clear Protect") { clearDifferenceSelection(reveal: false) }
              }
            }
            .disabled(layer.isLocked)
          }
        }

        InspectorSlider(
          title: "Opacity",
          value: layer.opacity,
          range: 0...1,
          format: .percent,
          layout: .inline,
          send: send,
          actionName: "Change Opacity"
        ) { .setLayerOpacity(layer.id, $0) }

        InspectorSlider(
          title: "Fill",
          value: layer.fill,
          range: 0...1,
          format: .percent,
          layout: .inline,
          send: send,
          actionName: "Change Fill"
        ) { .setLayerFill(layer.id, $0) }
      }
    }
  }

  private func differenceOption(
    _ name: String, update: (inout LayerCompositing) -> Void
  ) -> EditorAction {
    var options = layer.compositing
    update(&options)
    return .setLayerDifferenceOptions(layer.id, options, actionName: name)
  }

  private func differenceSelection(reveal: Bool) {
    guard let selection else { return }
    let name = reveal ? "Reveal Difference Selection" : "Protect Difference Selection"
    let action = differenceOption(name) { options in
      if reveal { options.differenceRevealMask = selection }
      else { options.differenceProtectMask = selection }
    }
    send(.change(action, interactive: false))
  }

  private func clearDifferenceSelection(reveal: Bool) {
    let name = reveal ? "Clear Difference Reveal" : "Clear Difference Protect"
    let action = differenceOption(name) { options in
      if reveal { options.differenceRevealMask = nil }
      else { options.differenceProtectMask = nil }
    }
    send(.change(action, interactive: false))
  }
}

/// A disclosure section embedded in the right panel's layer details.
///
/// It deliberately uses the same flat header as History and Snapshots instead
/// of the boxed inspector style. The negative horizontal inset lets the header
/// and divider span the details column while the revealed controls keep the
/// panel's standard 12-point content inset.
struct RightPanelDisclosureSection<Content: View, Accessory: View>: View {
  let title: String
  let systemImage: String?
  let helpText: String?
  let content: Content
  let accessory: Accessory

  @AppStorage private var isExpanded: Bool

  init(
    _ title: String,
    id: String,
    systemImage: String? = nil,
    startsExpanded: Bool = true,
    helpText: String? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.systemImage = systemImage
    self.helpText = helpText
    self.content = content()
    self.accessory = accessory()
    _isExpanded = AppStorage(
      wrappedValue: startsExpanded, "PixeltjeMac.layersInspector.\(id).isExpanded")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        PanelDisclosureHeader(
          title: title,
          systemImage: systemImage,
          isExpanded: isExpanded,
          helpText: helpText
        ) {
          withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
        }
        .frame(maxWidth: .infinity)

        accessory
          .padding(.trailing, 12)
      }

      if isExpanded {
        content
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()
    }
    .padding(.horizontal, -12)
  }
}

extension RightPanelDisclosureSection where Accessory == EmptyView {
  init(
    _ title: String,
    id: String,
    systemImage: String? = nil,
    startsExpanded: Bool = true,
    helpText: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.init(
      title,
      id: id,
      systemImage: systemImage,
      startsExpanded: startsExpanded,
      helpText: helpText,
      content: content,
      accessory: { EmptyView() }
    )
  }
}

/// The width of the label column in inspector rows, so the controls of
/// neighbouring rows line up down the panel.
private let inspectorLabelWidth: CGFloat = 52

/// One section of the layers inspector: a titled box whose body folds away.
///
/// Every section in this panel uses it, so they share one header — chevron,
/// title, and an optional control on the right such as a switch or a size —
/// instead of mixing plain group boxes, disclosure groups and loose headlines.
/// Expansion is remembered per section in user defaults, so a section folded
/// shut stays shut as the selection moves between layers. It is view state:
/// nothing here reaches the recipe or the undo history.
private struct InspectorSection<Content: View, Accessory: View>: View {
  let title: String
  let helpText: String?
  let content: Content
  let accessory: Accessory

  @AppStorage private var isExpanded: Bool

  init(
    _ title: String,
    id: String,
    startsExpanded: Bool = true,
    helpText: String? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.helpText = helpText
    self.content = content()
    self.accessory = accessory()
    _isExpanded = AppStorage(
      wrappedValue: startsExpanded, "PixeltjeMac.layersInspector.\(id).isExpanded")
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 6) {
          Button {
            withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
              Text(title)
                .font(.headline)
                .lineLimit(1)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(helpText ?? "")
          .accessibilityLabel(title)
          .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
          .accessibilityAddTraits(.isHeader)

          accessory
        }

        if isExpanded {
          content
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}

extension InspectorSection where Accessory == EmptyView {
  init(
    _ title: String,
    id: String,
    startsExpanded: Bool = true,
    helpText: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.init(
      title, id: id, startsExpanded: startsExpanded, helpText: helpText, content: content,
      accessory: { EmptyView() })
  }
}

/// A label and its control on one line, the label in the shared column.
private struct InspectorRow<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: inspectorLabelWidth, alignment: .leading)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The line above the sections that says what is selected.
private struct InspectorHeader: View {
  let symbolName: String
  let title: String
  let subtitle: String
  var isLocked = false
  var isDisabled = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if isLocked {
        Image(systemName: "lock.fill")
          .foregroundStyle(.secondary)
          .help("Locked")
          .accessibilityLabel("Locked")
      }
      if isDisabled {
        Image(systemName: "eye.slash")
          .foregroundStyle(.secondary)
          .help("Disabled")
          .accessibilityLabel("Disabled")
      }
    }
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }
}

/// Names the selected layer, with the detail its list row has no room for.
///
/// This replaces the per-type headlines each layer inspector used to draw for
/// itself, and the folded Layer Details box that repeated the row.
private struct SelectedLayerHeader: View {
  let layer: ProjectLayer

  var body: some View {
    InspectorHeader(
      symbolName: layer.symbolName,
      title: layer.name,
      subtitle: subtitle,
      isLocked: layer.isLocked,
      isDisabled: !layer.isEnabled && !layer.isCanvasLayer
    )
  }

  private var subtitle: String {
    var parts = [layer.contentDescription]
    if case .developedRaw(let raw) = layer.content,
      let sourceFilename = raw.source?.originalFilename
    {
      parts.append(sourceFilename)
    } else if layer.rowDescription != layer.contentDescription {
      parts.append(layer.rowDescription)
    }
    return parts.joined(separator: " · ")
  }
}

/// One slider that reports a whole drag as a single undoable step.
private struct InspectorSlider: View {
  enum ValueFormat {
    case percent
    case decimal(Int)
  }

  /// `stacked` puts the title and value above the slider; `inline` keeps all
  /// three on one line with the title in the shared label column.
  enum Layout {
    case stacked
    case inline
  }

  let title: String
  let value: Double
  let range: ClosedRange<Double>
  var step: Double?
  let format: ValueFormat
  let layout: Layout
  let send: (InspectorIntent) -> Void
  let actionName: String
  let action: (Double) -> EditorAction

  init(
    title: String,
    value: Double,
    range: ClosedRange<Double>,
    step: Double? = nil,
    format: ValueFormat,
    layout: Layout = .stacked,
    send: @escaping (InspectorIntent) -> Void,
    actionName: String,
    action: @escaping (Double) -> EditorAction
  ) {
    self.title = title
    self.value = value
    self.range = range
    self.step = step
    self.format = format
    self.layout = layout
    self.send = send
    self.actionName = actionName
    self.action = action
  }

  var body: some View {
    switch layout {
    case .stacked:
      VStack(spacing: 4) {
        HStack {
          Text(title)
          Spacer()
          Text(formattedValue)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        slider
      }
      .font(.caption)
    case .inline:
      HStack(spacing: 8) {
        Text(title)
          .foregroundStyle(.secondary)
          .frame(width: inspectorLabelWidth, alignment: .leading)
        slider
        Text(formattedValue)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(width: 36, alignment: .trailing)
      }
      .font(.caption)
    }
  }

  @ViewBuilder
  private var slider: some View {
    let binding = Binding(
      get: { value },
      set: { send(.change(action($0), interactive: true)) }
    )
    if let step {
      Slider(value: binding, in: range, step: step, onEditingChanged: gestureChanged)
    } else {
      Slider(value: binding, in: range, onEditingChanged: gestureChanged)
    }
  }

  private var formattedValue: String {
    switch format {
    case .percent:
      "\((value * 100).formatted(.number.precision(.fractionLength(0))))%"
    case .decimal(let places):
      value.formatted(.number.precision(.fractionLength(places)))
    }
  }

  private func gestureChanged(_ editing: Bool) {
    if editing {
      send(.beginGesture)
    } else {
      send(.endGesture(actionName))
    }
  }
}

/// A selected text layer in the layers inspector.
///
/// Editing belongs to the Text tool, whose settings live in the left panel per
/// the placement rule, so this only says what the layer holds and where to
/// change it.
private struct TextLayerSummaryView: View {
  let text: TextLayer

  var body: some View {
    InspectorSection("Text", id: "text-layer") {
      VStack(alignment: .leading, spacing: 6) {
        Text(text.text.isEmpty ? "Empty text layer." : text.text)
          .font(.caption)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
        Text("Choose the Text tool to edit the wording, font, size, alignment and color.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct AdjustmentLayerInspectorView: View {
  let layerID: ProjectLayerID
  let adjustment: AdjustmentRecipe
  let affectedCount: Int
  let send: (InspectorIntent) -> Void

  var body: some View {
    InspectorSection(adjustment.label, id: "adjustment") {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 11) {
          switch adjustment {
          case .exposure(let ev):
            InspectorSlider(
              title: "Exposure",
              value: ev,
              range: -5...5,
              format: .decimal(2),
              send: send,
              actionName: "Adjust Layer"
            ) { .setAdjustment(layerID, .exposure(ev: $0)) }
          case .colorControls(let brightness, let contrast, let saturation):
            InspectorSlider(
              title: "Brightness",
              value: brightness,
              range: -1...1,
              format: .decimal(2),
              send: send,
              actionName: "Adjust Layer"
            ) {
              .setAdjustment(
                layerID,
                .colorControls(brightness: $0, contrast: contrast, saturation: saturation))
            }
            InspectorSlider(
              title: "Contrast",
              value: contrast,
              range: 0.25...4,
              format: .decimal(2),
              send: send,
              actionName: "Adjust Layer"
            ) {
              .setAdjustment(
                layerID,
                .colorControls(brightness: brightness, contrast: $0, saturation: saturation))
            }
            InspectorSlider(
              title: "Saturation",
              value: saturation,
              range: 0...2,
              format: .decimal(2),
              send: send,
              actionName: "Adjust Layer"
            ) {
              .setAdjustment(
                layerID,
                .colorControls(brightness: brightness, contrast: contrast, saturation: $0))
            }
          case .curves(let curve):
            AdjustmentCurveControls(layerID: layerID, curve: curve, send: send)
          case .levels(let levels):
            InspectorSlider(
              title: "Black point", value: levels.blackPoint, range: 0...0.95,
              format: .decimal(2), send: send, actionName: "Adjust Levels Black Point"
            ) {
              .setAdjustment(
                layerID,
                .levels(
                  LevelsAdjustment(
                    blackPoint: $0, whitePoint: levels.whitePoint, gamma: levels.gamma)))
            }
            InspectorSlider(
              title: "White point", value: levels.whitePoint, range: 0.05...1,
              format: .decimal(2), send: send, actionName: "Adjust Levels White Point"
            ) {
              .setAdjustment(
                layerID,
                .levels(
                  LevelsAdjustment(
                    blackPoint: levels.blackPoint, whitePoint: $0, gamma: levels.gamma)))
            }
            InspectorSlider(
              title: "Gamma", value: levels.gamma, range: 0.1...4,
              format: .decimal(2), send: send, actionName: "Adjust Levels Gamma"
            ) {
              .setAdjustment(
                layerID,
                .levels(
                  LevelsAdjustment(
                    blackPoint: levels.blackPoint, whitePoint: levels.whitePoint, gamma: $0)))
            }
          case .hueSaturation(let values):
            InspectorSlider(
              title: "Hue", value: values.hue, range: -180...180,
              format: .decimal(0), send: send, actionName: "Adjust Hue"
            ) {
              .setAdjustment(
                layerID,
                .hueSaturation(
                  HueSaturationAdjustment(
                    hue: $0, saturation: values.saturation, lightness: values.lightness)))
            }
            InspectorSlider(
              title: "Saturation", value: values.saturation, range: -100...100,
              format: .decimal(0), send: send, actionName: "Adjust Saturation"
            ) {
              .setAdjustment(
                layerID,
                .hueSaturation(
                  HueSaturationAdjustment(
                    hue: values.hue, saturation: $0, lightness: values.lightness)))
            }
            InspectorSlider(
              title: "Lightness", value: values.lightness, range: -100...100,
              format: .decimal(0), send: send, actionName: "Adjust Lightness"
            ) {
              .setAdjustment(
                layerID,
                .hueSaturation(
                  HueSaturationAdjustment(
                    hue: values.hue, saturation: values.saturation, lightness: $0)))
            }
          case .blackAndWhite(let values):
            InspectorSlider(
              title: "Amount", value: values.amount, range: 0...1,
              format: .percent, send: send, actionName: "Adjust Black & White Amount"
            ) {
              .setAdjustment(
                layerID,
                .blackAndWhite(
                  BlackAndWhiteAdjustment(
                    redWeight: values.redWeight, greenWeight: values.greenWeight,
                    blueWeight: values.blueWeight, amount: $0)))
            }
            InspectorSlider(
              title: "Red mix", value: values.redWeight, range: 0...1,
              format: .percent, send: send, actionName: "Adjust Black & White Red Mix"
            ) {
              .setAdjustment(
                layerID,
                .blackAndWhite(
                  BlackAndWhiteAdjustment(
                    redWeight: $0, greenWeight: values.greenWeight, blueWeight: values.blueWeight,
                    amount: values.amount)))
            }
            InspectorSlider(
              title: "Green mix", value: values.greenWeight, range: 0...1,
              format: .percent, send: send, actionName: "Adjust Black & White Green Mix"
            ) {
              .setAdjustment(
                layerID,
                .blackAndWhite(
                  BlackAndWhiteAdjustment(
                    redWeight: values.redWeight, greenWeight: $0, blueWeight: values.blueWeight,
                    amount: values.amount)))
            }
            InspectorSlider(
              title: "Blue mix", value: values.blueWeight, range: 0...1,
              format: .percent, send: send, actionName: "Adjust Black & White Blue Mix"
            ) {
              .setAdjustment(
                layerID,
                .blackAndWhite(
                  BlackAndWhiteAdjustment(
                    redWeight: values.redWeight, greenWeight: values.greenWeight, blueWeight: $0,
                    amount: values.amount)))
            }
          case .colorLookup(let lookup):
            Picker(
              "Lookup",
              selection: Binding(
                get: { lookup.style },
                set: {
                  send(
                    .change(
                      .setNamedAdjustment(
                        layerID,
                        .colorLookup(ColorLookupAdjustment(style: $0, amount: lookup.amount)),
                        actionName: "Choose Color Lookup"), interactive: false))
                }
              )
            ) {
              ForEach(ColorLookupStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            InspectorSlider(
              title: "Amount", value: lookup.amount, range: 0...1,
              format: .percent, send: send, actionName: "Adjust Color Lookup Amount"
            ) {
              .setAdjustment(
                layerID, .colorLookup(ColorLookupAdjustment(style: lookup.style, amount: $0)))
            }
          case .gradientMap(let map):
            Picker(
              "Gradient",
              selection: Binding(
                get: { map.style },
                set: {
                  send(
                    .change(
                      .setNamedAdjustment(
                        layerID,
                        .gradientMap(
                          GradientMapAdjustment(
                            style: $0, amount: map.amount, reversed: map.reversed)),
                        actionName: "Choose Gradient Map"), interactive: false))
                }
              )
            ) {
              ForEach(GradientMapStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle(
              "Reverse",
              isOn: Binding(
                get: { map.reversed },
                set: {
                  send(
                    .change(
                      .setNamedAdjustment(
                        layerID,
                        .gradientMap(
                          GradientMapAdjustment(style: map.style, amount: map.amount, reversed: $0)),
                        actionName: "Reverse Gradient Map"), interactive: false))
                }
              ))
            InspectorSlider(
              title: "Amount", value: map.amount, range: 0...1,
              format: .percent, send: send, actionName: "Adjust Gradient Map Amount"
            ) {
              .setAdjustment(
                layerID,
                .gradientMap(
                  GradientMapAdjustment(style: map.style, amount: $0, reversed: map.reversed)))
            }
          case .invert:
            Text("Invert has no settings.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(
          affectedCount == 1
            ? "Changes 1 visible layer below it in its group."
            : "Changes \(affectedCount) visible layers below it in its group."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct AdjustmentCurveControls: View {
  let layerID: ProjectLayerID
  let curve: ToneCurveRecipe
  let send: (InspectorIntent) -> Void

  @StateObject private var state = ToneCurveEditorState()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Channel", selection: $state.channel) {
        ForEach(ToneCurveRecipe.Channel.allCases, id: \.self) { channel in
          Text(channel.label).tag(channel)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      ToneCurveGraph(
        state: state,
        curve: curve,
        update: update,
        beginGesture: { send(.beginGesture) },
        endGesture: { send(.endGesture("Edit Curves Adjustment")) }
      )
      .frame(height: 170)
      Button("Reset \(state.channel.label) Curve") {
        var changed = curve
        changed[state.channel] = .identity
        send(
          .change(
            .setNamedAdjustment(layerID, .curves(changed), actionName: "Reset Curves Adjustment"),
            interactive: false))
      }
      .disabled(curve[state.channel].isIdentity)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .onAppear { state.mode = .point }
  }

  private func update(_ points: PointToneCurve, interactive: Bool) {
    var changed = curve
    changed[state.channel] = points
    send(.change(.setAdjustment(layerID, .curves(changed)), interactive: interactive))
  }
}

private struct ImageLayerInspectorView: View {
  let image: ImageLayer

  var body: some View {
    RightPanelDisclosureSection(
      "Linked Image",
      id: "linked-image",
      systemImage: "photo.on.rectangle",
      startsExpanded: false,
      helpText: "The project stores this link and where the image sits on the canvas, never a "
        + "copy of its pixels. Editing or moving the file on disk changes what the project shows."
    ) {
      VStack(alignment: .leading, spacing: 6) {
        LabeledContent("File", value: image.source.originalFilename)
        LabeledContent("Pixels", value: image.naturalSizeDescription)
        LabeledContent(
          "Placed",
          value: "\(Int(image.frame.width)) × \(Int(image.frame.height)) px"
        )
        if let path = image.source.linkedPath {
          LabeledContent("Path", value: path)
            .lineLimit(3)
            .truncationMode(.middle)
            .help(path)
        }
      }
      .font(.caption)
    }
  }
}

/// The right panel's Canvas section: the document extent, and everything used
/// to work on it.
///
/// The split it keeps is the one the architecture asks for. The extent, the
/// guides, the grid and what a drag snaps to are recipe state, so each edit
/// goes through `ProjectDocument` as one named undoable step. Whether the
/// rulers, guides or grid are *drawn*, and whether snapping is live at all, are
/// working preferences: those are `CanvasViewSettings`, the same object the
/// View menu drives, so the two surfaces are one switch seen twice.
private struct CanvasLayerInspectorView: View {
  let canvas: CanvasRecipe
  let settings: CanvasSettingsRecipe
  let isEditable: Bool
  @ObservedObject var viewSettings: CanvasViewSettings
  let send: (InspectorIntent) -> Void

  // The macOS 27 SDK also exports a State macro. Name the property-wrapper type
  // explicitly so Command Line Tools builds do not require SwiftUIMacros.
  private typealias IntState = SwiftUI.State<Int>
  private typealias AnchorState = SwiftUI.State<CanvasAnchor>
  private typealias AspectState = SwiftUI.State<String?>
  @IntState private var draftWidth = 0
  @IntState private var draftHeight = 0
  @AnchorState private var anchor: CanvasAnchor = .center
  @AspectState private var selectedAspectID: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      canvasSize
      rulersAndGuides
      grid
      snapping
    }
    .onAppear(perform: adoptCanvas)
    .onChange(of: canvas) { _, _ in adoptCanvas() }
  }

  // MARK: - Canvas size

  /// The extent as a compact form: shape and preset menus, then the two pixel
  /// fields beside the anchor they resize around, as a canvas-size dialog lays
  /// them out. The current size sits in the header, so it stays readable with
  /// the section folded.
  private var canvasSize: some View {
    InspectorSection(
      "Canvas Size",
      id: "canvas-size",
      helpText: "The canvas holds the document's size and nothing else. Everything outside it "
        + "shows the darker checkerboard."
    ) {
      if isEditable {
        VStack(alignment: .leading, spacing: 8) {
          InspectorRow("Aspect") {
            Picker("Aspect ratio", selection: aspectSelection) {
              Text("Any").tag(nil as String?)
              Divider()
              ForEach(CanvasRecipe.aspectPresets) { aspect in
                Text("\(aspect.name)  \(aspect.description)").tag(aspect.id as String?)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
          }

          InspectorRow("Preset") {
            Picker("Size preset", selection: sizeSelection) {
              Text("Custom").tag(nil as String?)
              Divider()
              ForEach(visibleSizePresets) { preset in
                Text(presetTitle(preset)).tag(preset.id as String?)
              }
            }
            .pickerStyle(.menu)
            .labelsHidden()
          }

          HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
              InspectorRow("Width") { pixelField("Width", value: $draftWidth) }
              InspectorRow("Height") { pixelField("Height", value: $draftHeight) }
            }
            anchorPicker
          }

          HStack {
            Spacer(minLength: 0)
            Button("Resize Canvas", action: applyResize)
              .disabled(!canApplyResize)
              .help("Resize changes the canvas bounds, not the size of existing layers.")
          }
        }
      } else {
        Text(
          "A RAW-backed document takes its canvas from the developed image, so the size follows "
            + "the RAW and its crop."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    } accessory: {
      Text(sizeDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func pixelField(_ title: String, value: Binding<Int>) -> some View {
    HStack(spacing: 4) {
      TextField(title, value: value, format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .labelsHidden()
        .frame(width: 64)
        .accessibilityLabel("\(title) in pixels")
      Text("px")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// The nine-point anchor, laid out the way a canvas-size dialog draws it.
  private var anchorPicker: some View {
    VStack(spacing: 4) {
      VStack(spacing: 2) {
        ForEach(Array(CanvasAnchor.rows.enumerated()), id: \.offset) { _, row in
          HStack(spacing: 2) {
            ForEach(row, id: \.self) { candidate in
              Button {
                anchor = candidate
              } label: {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                  .fill(
                    anchor == candidate ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
                  )
                  .frame(width: 14, height: 14)
                  .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                      .strokeBorder(.separator, lineWidth: 0.5)
                  )
              }
              .buttonStyle(.plain)
              .help(candidate.label)
              .accessibilityLabel(candidate.label)
              .accessibilityAddTraits(anchor == candidate ? [.isButton, .isSelected] : .isButton)
            }
          }
        }
      }
      Text("Anchor")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .help("Existing layers and guides keep their distance from the anchored edge.")
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Anchor")
  }

  /// Choosing a shape narrows the preset menu to it and picks the listed size
  /// nearest the current pixel count; Any lists every preset again.
  private var aspectSelection: Binding<String?> {
    Binding(
      get: { selectedAspectID },
      set: { id in
        guard id != selectedAspectID else { return }
        selectedAspectID = id
        guard let aspect = CanvasRecipe.aspectPresets.first(where: { $0.id == id }),
          let preset = aspect.closestSize(to: draftCanvas)
        else { return }
        draftWidth = preset.canvas.width
        draftHeight = preset.canvas.height
      }
    )
  }

  /// A preset's menu title. With a shape chosen, every entry shares it, so the
  /// ratio is only spelled out when the menu lists them all.
  private func presetTitle(_ preset: CanvasSizePreset) -> String {
    let size = "\(preset.canvas.width) × \(preset.canvas.height)"
    guard selectedAspectID == nil, let name = preset.canvas.aspectPreset?.name else {
      return size
    }
    return "\(size)  (\(name))"
  }

  private var visibleSizePresets: [CanvasSizePreset] {
    guard let selectedAspectID,
      let aspect = CanvasRecipe.aspectPresets.first(where: { $0.id == selectedAspectID })
    else { return CanvasRecipe.presets }
    return aspect.sizes
  }

  private var sizeSelection: Binding<String?> {
    Binding(
      get: { visibleSizePresets.first(where: { $0.canvas == draftCanvas })?.id },
      set: { id in
        guard let preset = visibleSizePresets.first(where: { $0.id == id }) else {
          return
        }
        draftWidth = preset.canvas.width
        draftHeight = preset.canvas.height
      }
    )
  }

  private var draftCanvas: CanvasRecipe {
    CanvasRecipe(width: draftWidth, height: draftHeight)
  }

  private var canApplyResize: Bool {
    draftCanvas.isResolved && draftCanvas != canvas
  }

  private func applyResize() {
    guard canApplyResize else { return }
    send(.change(.resizeCanvas(draftCanvas, anchor: anchor), interactive: false))
  }

  /// Takes the fields back to what the document says whenever the canvas
  /// changes underneath them, so an undo is visible in the panel too.
  private func adoptCanvas() {
    draftWidth = canvas.width
    draftHeight = canvas.height
  }

  private var sizeDescription: String {
    guard canvas.isResolved else { return "Not set yet" }
    let size = "\(canvas.width) × \(canvas.height) px"
    guard let name = canvas.presetName else { return size }
    return "\(size) (\(name))"
  }

  // MARK: - Rulers and guides

  /// Each view toggle now sits in the section for what it shows: rulers and
  /// guides here, the grid and snapping as the switch in their own headers.
  private var rulersAndGuides: some View {
    InspectorSection(
      "Rulers & Guides",
      id: "canvas-guides",
      helpText: "Showing rulers and guides is a working preference, mirrored in the View menu and "
        + "not saved with the project. Drag out of a ruler to add a guide; drag one off the "
        + "canvas to delete it."
    ) {
      VStack(alignment: .leading, spacing: 8) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 14) { overlayToggles }
          VStack(alignment: .leading, spacing: 6) { overlayToggles }
        }
        .toggleStyle(.checkbox)

        HStack(spacing: 6) {
          Text(guideCountDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Clear Guides") {
            send(
              .change(
                .setCanvasSettings(settings.removingAllGuides(), actionName: "Clear Guides"),
                interactive: false
              ))
          }
          .disabled(settings.guides.isEmpty)
        }
      }
    }
  }

  @ViewBuilder
  private var overlayToggles: some View {
    Toggle(CanvasViewOption.rulers.panelTitle, isOn: viewSettings.binding(.rulers))
    Toggle(CanvasViewOption.guides.panelTitle, isOn: viewSettings.binding(.guides))
    Toggle(CanvasViewOption.lockGuides.panelTitle, isOn: viewSettings.binding(.lockGuides))
      .disabled(!viewSettings.isOn(.guides))
  }

  /// A View-menu toggle shown as a switch in a section header, so whether the
  /// grid or snapping is on reads at a glance with the section folded.
  private func headerSwitch(_ option: CanvasViewOption) -> some View {
    Toggle(option.title, isOn: viewSettings.binding(option))
      .toggleStyle(.switch)
      .controlSize(.mini)
      .labelsHidden()
      .help("\(option.title), mirrored in the View menu")
  }

  /// A number with its unit and a stepper, for the grid and snap settings.
  ///
  /// Typed values are clamped to the stepper's range, so the field cannot store
  /// what the stepper would refuse.
  private func numberRow(
    _ title: String,
    value: Binding<Double>,
    in range: ClosedRange<Double>,
    step: Double,
    unit: String
  ) -> some View {
    let clamped = Binding<Double>(
      get: { value.wrappedValue },
      set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
    )
    return HStack(spacing: 6) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      TextField(title, value: clamped, format: .number.precision(.fractionLength(0)))
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .labelsHidden()
        .frame(width: 56)
      Text(unit)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .leading)
      Stepper(title, value: clamped, in: range, step: step)
        .labelsHidden()
    }
  }

  private var guideCountDescription: String {
    switch settings.guides.count {
    case 0: "No guides"
    case 1: "1 guide"
    case let count: "\(count) guides"
    }
  }

  // MARK: - Grid

  private var grid: some View {
    InspectorSection("Grid", id: "canvas-grid", startsExpanded: false) {
      VStack(alignment: .leading, spacing: 6) {
        numberRow("Spacing", value: gridSpacing, in: 1...8_192, step: 10, unit: "px")
        numberRow("Subdivisions", value: gridSubdivisions, in: 1...64, step: 1, unit: "")
        Text(
          "Heavy lines every \(settings.grid.spacing.formatted(.number.precision(.fractionLength(0)))) px, "
            + "light ones every \(settings.grid.subdivisionSpacing.formatted(.number.precision(.fractionLength(1)))) px."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    } accessory: {
      headerSwitch(.grid)
    }
  }

  private var gridSpacing: Binding<Double> {
    Binding(
      get: { settings.grid.spacing },
      set: { spacing in
        guard spacing != settings.grid.spacing else { return }
        var next = settings
        next.grid = CanvasGridRecipe(
          spacing: spacing, subdivisions: settings.grid.subdivisions)
        send(
          .change(
            .setCanvasSettings(next, actionName: "Change Grid Spacing"), interactive: false))
      }
    )
  }

  private var gridSubdivisions: Binding<Double> {
    Binding(
      get: { Double(settings.grid.subdivisions) },
      set: { value in
        let subdivisions = Int(value.rounded())
        guard subdivisions != settings.grid.subdivisions else { return }
        var next = settings
        next.grid = CanvasGridRecipe(
          spacing: settings.grid.spacing, subdivisions: subdivisions)
        send(
          .change(
            .setCanvasSettings(next, actionName: "Change Grid Subdivisions"),
            interactive: false
          ))
      }
    )
  }

  // MARK: - Snapping

  private var snapping: some View {
    let kinds = CanvasSnapTargetKind.allCases
    return InspectorSection(
      "Snapping",
      id: "canvas-snapping",
      startsExpanded: false,
      helpText: "Which targets are live is part of the project. The switch is the View menu's "
        + "Snap toggle, a working preference."
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
          ForEach(Array(stride(from: 0, to: kinds.count, by: 2)), id: \.self) { start in
            GridRow {
              ForEach(kinds[start..<min(start + 2, kinds.count)], id: \.self) { kind in
                Toggle(kind.label, isOn: snapTarget(kind))
              }
            }
          }
        }
        .toggleStyle(.checkbox)
        numberRow("Pull distance", value: snapThreshold, in: 0...40, step: 1, unit: "pt")
      }
      .disabled(!viewSettings.isOn(.snap))
    } accessory: {
      headerSwitch(.snap)
    }
  }

  private func snapTarget(_ kind: CanvasSnapTargetKind) -> Binding<Bool> {
    Binding(
      get: { settings.snapping.contains(kind) },
      set: { isOn in
        guard isOn != settings.snapping.contains(kind) else { return }
        var next = settings
        next.snapping = settings.snapping.setting(kind, enabled: isOn)
        send(
          .change(
            .setCanvasSettings(next, actionName: "Change Snapping"),
            interactive: false
          ))
      }
    )
  }

  private var snapThreshold: Binding<Double> {
    Binding(
      get: { settings.snapping.thresholdInScreenPoints },
      set: { threshold in
        guard threshold != settings.snapping.thresholdInScreenPoints else { return }
        var next = settings
        next.snapping = CanvasSnapRecipe(
          targets: settings.snapping.targets,
          thresholdInScreenPoints: threshold
        )
        send(
          .change(
            .setCanvasSettings(next, actionName: "Change Snap Distance"),
            interactive: false
          ))
      }
    )
  }
}
