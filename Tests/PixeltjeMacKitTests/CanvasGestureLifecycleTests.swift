import AppKit
import MetalKit
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
private final class CanvasIntentRecorder {
  var recipe: ProjectRecipe
  var intents: [CanvasIntent] = []

  init(recipe: ProjectRecipe) {
    self.recipe = recipe
  }

  func receive(_ intent: CanvasIntent) {
    intents.append(intent)
    if case .change(let action, _) = intent {
      recipe = recipe.applying(action)
    }
  }

  var beginGestureCount: Int {
    intents.reduce(into: 0) { count, intent in
      if case .beginGesture = intent { count += 1 }
    }
  }

  var endGestureCount: Int {
    intents.reduce(into: 0) { count, intent in
      if case .endGesture = intent { count += 1 }
    }
  }

  var cancelledBrushCount: Int {
    intents.reduce(into: 0) { count, intent in
      if case .cancelBrushStroke = intent { count += 1 }
    }
  }

  var deselectionCount: Int {
    intents.reduce(into: 0) { count, intent in
      if case .commitSelection(nil, actionName: "Deselect") = intent { count += 1 }
    }
  }

  var addedMaskCount: Int {
    intents.reduce(into: 0) { count, intent in
      guard case .change(let action, _) = intent else { return }
      if case .addMask = action { count += 1 }
    }
  }

  var removedMaskCount: Int {
    intents.reduce(into: 0) { count, intent in
      guard case .change(let action, _) = intent else { return }
      if case .removeMask = action { count += 1 }
    }
  }
}

@MainActor
private func mountedCanvas(
  recipe: ProjectRecipe,
  recorder: CanvasIntentRecorder
) -> (canvas: MetalCanvasView, window: NSWindow) {
  let frame = CGRect(x: 0, y: 0, width: 240, height: 240)
  let window = NSWindow(
    contentRect: frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
  )
  let canvas = MetalCanvasView(viewSettings: CanvasViewSettings()) {
    recorder.receive($0)
  }
  canvas.frame = frame
  window.contentView = canvas
  canvas.drawableSize = frame.size
  canvas.updateRecipe(recipe)
  canvas.layoutSubtreeIfNeeded()
  return (canvas, window)
}

@MainActor
private func mouseEvent(
  _ type: NSEvent.EventType,
  at point: CGPoint,
  in window: NSWindow
) throws -> NSEvent {
  try #require(
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )
  )
}

@MainActor
private func escapeKeyEvent(in window: NSWindow) throws -> NSEvent {
  try #require(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false,
      keyCode: 53
    )
  )
}

private func canvasRecipe(with layer: ProjectLayer? = nil) -> ProjectRecipe {
  var recipe = ProjectRecipe()
  let canvas = ProjectLayer.canvasBase(CanvasRecipe(width: 100, height: 100))
  if let layer {
    recipe.layerStack = LayerStackRecipe(layers: [layer, canvas], activeLayerID: layer.id)
  } else {
    recipe.layerStack = LayerStackRecipe(layers: [canvas], activeLayerID: canvas.id)
  }
  return recipe
}

private func movableImageLayer() -> ProjectLayer {
  ProjectLayer.image(
    ImageLayer(
      source: SourceReference(
        originalFilename: "gesture.png",
        linkedPath: "/Pictures/gesture.png",
        securityScopedBookmark: nil,
        fingerprint: SourceFingerprint(byteLength: 1, modificationDate: nil)
      ),
      frame: LayerFrame(x: 20, y: 20, width: 40, height: 40),
      naturalWidth: 40,
      naturalHeight: 40
    )
  )
}

@MainActor
@Test func switchingToolsCancelsOneMoveGestureAndBalancesUndoBracketing() throws {
  let recipe = canvasRecipe(with: movableImageLayer())
  let recorder = CanvasIntentRecorder(recipe: recipe)
  let mounted = mountedCanvas(recipe: recipe, recorder: recorder)
  let canvas = mounted.canvas
  canvas.setTool(.move)

  canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 96, y: 96), in: mounted.window))
  canvas.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 120, y: 108), in: mounted.window))
  canvas.setTool(.brush)

  #expect(!canvas.hasActiveGesture)
  #expect(recorder.beginGestureCount == 1)
  #expect(recorder.endGestureCount == 1)
  #expect(recorder.recipe == recipe)
}

@MainActor
@Test func escapeCancelsMaskPlacementInsteadOfCommittingThePartialMask() throws {
  let layer = ProjectLayer.paint(name: "Mask target")
  let recipe = canvasRecipe(with: layer)
  let recorder = CanvasIntentRecorder(recipe: recipe)
  let mounted = mountedCanvas(recipe: recipe, recorder: recorder)
  let canvas = mounted.canvas
  canvas.setMaskTool(
    MaskToolState(generatorKind: .rectangle, activeLayerID: layer.id)
  )
  canvas.setTool(.masks)

  canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 96, y: 96), in: mounted.window))
  canvas.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 144, y: 144), in: mounted.window))
  canvas.keyDown(with: try escapeKeyEvent(in: mounted.window))

  #expect(!canvas.hasActiveGesture)
  #expect(recorder.beginGestureCount == 1)
  #expect(recorder.endGestureCount == 1)
  #expect(recorder.addedMaskCount == 1)
  #expect(recorder.removedMaskCount == 1)
  #expect(recorder.recipe == recipe)
}

@MainActor
@Test func escapeDeselectsAMarqueeSelectionRegardlessOfTheActiveTool() throws {
  var recipe = canvasRecipe()
  recipe.selection = .selecting(.rectangle(.full))

  for tool in EditorTool.allCases {
    let recorder = CanvasIntentRecorder(recipe: recipe)
    let mounted = mountedCanvas(recipe: recipe, recorder: recorder)
    mounted.canvas.setTool(tool)

    mounted.canvas.keyDown(with: try escapeKeyEvent(in: mounted.window))

    #expect(recorder.deselectionCount == 1)
  }
}

@MainActor
@Test func removingTheCanvasFromItsWindowCancelsBrushInputAndRestoresCoalescing() throws {
  let recipe = canvasRecipe()
  let recorder = CanvasIntentRecorder(recipe: recipe)
  let mounted = mountedCanvas(recipe: recipe, recorder: recorder)
  let canvas = mounted.canvas
  let originalCoalescingState = NSEvent.isMouseCoalescingEnabled
  canvas.setTool(.brush)

  canvas.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 96, y: 96), in: mounted.window))
  #expect(canvas.hasActiveGesture)
  #expect(!NSEvent.isMouseCoalescingEnabled)

  mounted.window.contentView = NSView(frame: mounted.window.contentLayoutRect)

  #expect(!canvas.hasActiveGesture)
  #expect(recorder.cancelledBrushCount == 1)
  #expect(NSEvent.isMouseCoalescingEnabled == originalCoalescingState)
}
