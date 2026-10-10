import Foundation
import PixeltjeMacDomain

struct MagnetSelectionCommit: Equatable {
  var selection: MaskRecipe
  var actionName: String
}

/// The common commit boundary for every tool that captures a new selection
/// component. Keeping combination here gives Marquee/Lasso-style New, Add,
/// Subtract and Intersect semantics to pixel analysis and brush coverage
/// without teaching either producer about the rest of the selection recipe.
enum CapturedSelectionSupport {
  static func commit(
    captured: MaskRecipe,
    existing: MaskRecipe?,
    componentName: String,
    defaultActionName: String,
    combine: MaskCombineOperation?,
    feather: Double
  ) -> MagnetSelectionCommit? {
    guard var component = captured.components.first else { return nil }
    component.feather = SelectionToolState.clamped(feather, upTo: 250)
    component.name = componentName

    let selection: MaskRecipe
    if let existing, let combine {
      component.combine = combine
      selection = existing.adding(component)
    } else {
      component.combine = .add
      selection = MaskRecipe(name: MaskRecipe.selectionName, components: [component])
    }

    let actionName = switch combine {
    case .add?: "Add to Selection"
    case .subtract?: "Subtract from Selection"
    case .intersect?: "Intersect Selection"
    case nil: defaultActionName
    }
    return MagnetSelectionCommit(selection: selection, actionName: actionName)
  }
}

/// Pure decisions used around the asynchronous pixel capture. Keeping them
/// separate makes the two important invariants directly testable: a selection
/// edit does not make otherwise-current pixels stale, and combining a captured
/// region preserves its requested softness and operation.
enum MagnetSelectionSupport {
  static func acceptsDisplayedFrame(
    documentID: UUID,
    renderRevision: UInt64,
    frameDocumentID: UUID,
    frameRevision: UInt64,
    frameIsProxy: Bool
  ) -> Bool {
    frameDocumentID == documentID && frameRevision == renderRevision && !frameIsProxy
  }

  static func commit(
    captured: MaskRecipe,
    existing: MaskRecipe?,
    mode: MagnetSelectionMode,
    combine: MaskCombineOperation?,
    feather: Double
  ) -> MagnetSelectionCommit? {
    CapturedSelectionSupport.commit(
      captured: captured,
      existing: existing,
      componentName: mode.label,
      defaultActionName: "Magnet Selection",
      combine: combine,
      feather: feather)
  }
}
