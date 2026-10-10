import Foundation
import PixeltjeMacDomain
import Testing

private func placedImage(
  x: Double = 100,
  y: Double = 50,
  width: Double = 640,
  height: Double = 480
) -> ImageLayer {
  ImageLayer(
    source: SourceReference(
      originalFilename: "sky.png",
      linkedPath: "/Pictures/sky.png",
      securityScopedBookmark: nil,
      fingerprint: SourceFingerprint(byteLength: 1024, modificationDate: nil)
    ),
    frame: LayerFrame(x: x, y: y, width: width, height: height),
    naturalWidth: 640,
    naturalHeight: 480
  )
}

private func canvasProject(width: Int = 1920, height: Int = 1080) -> ProjectRecipe {
  var project = ProjectRecipe()
  project.layerStack.canvas = CanvasRecipe(width: width, height: height)
  return project
}

@Test func movingAnImageLayerUsesPersistentPlacementAndKeepsItsLayoutFrame() {
  let layer = ProjectLayer.image(placedImage())
  let project = canvasProject().applying(.addImageLayer(layer))

  let moved = project.applying(.translateLayer(layer.id, byX: 25, y: -10))
  let transformed = moved.layerStack.layer(id: layer.id)

  #expect(transformed?.imageLayer?.frame == layer.imageLayer?.frame)
  #expect(transformed?.transform?.position == PixelPoint(x: 445, y: 280))

  // The delta composes, which is what lets a drag send the distance it has
  // travelled since the last event and a cancel send the same distance back.
  let returned = moved.applying(.translateLayer(layer.id, byX: -25, y: 10))
  #expect(returned == project)
}

@Test func aLayerCanBeMovedPartlyOffTheCanvas() {
  let layer = ProjectLayer.image(placedImage(x: 0, y: 0))
  let project = canvasProject().applying(.addImageLayer(layer))

  let moved = project.applying(.translateLayer(layer.id, byX: -200, y: -100))

  // Placement is not clamped: the render engine crops the composite back to the
  // canvas, so a layer may hang over an edge and come back later.
  #expect(moved.layerStack.frame(of: layer.id) == LayerFrame(x: -200, y: -100, width: 640, height: 480))
}

@Test func lockedLayersAndTheCanvasStayPut() {
  let project = ProjectRecipe(
    source: SourceReference(
      originalFilename: "capture.raf",
      linkedPath: "/Pictures/capture.raf",
      securityScopedBookmark: nil,
      fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
    )
  )

  // The developed RAW is the document extent rather than a placed layer, and
  // the canvas is that extent by definition.
  #expect(project.applying(.translateLayer(.rawBackground, byX: 10, y: 10)) == project)
  #expect(project.applying(.translateLayer(.canvas, byX: 10, y: 10)) == project)
  #expect(project.applying(.translateLayer(ProjectLayerID(), byX: 10, y: 10)) == project)
  #expect(project.applying(.translateLayer(.rawBackground, byX: 0, y: 0)) == project)
}

@Test func movingAVectorLayerCrossesTheSameFractionOfTheCanvas() throws {
  let path = VectorPath(
    anchors: [
      VectorAnchor(
        position: VectorPoint(x: 0.5, y: 0.5),
        incomingHandle: VectorPoint(x: 0.4, y: 0.5),
        outgoingHandle: VectorPoint(x: 0.6, y: 0.5),
        kind: .symmetric
      )
    ]
  )
  var stack = canvasProject(width: 1000, height: 500).layerStack
  let layerID = stack.ensureActiveVectorLayer()
  stack.appendPath(path, to: layerID)

  // 100 of 1000 canvas pixels across, and -50 of 500 down.
  let moved = stack.translating(layerID, byX: 100, y: -50)
  let anchor = try #require(moved.path(id: path.id)?.path.anchors.first)

  #expect(anchor.position == VectorPoint(x: 0.6, y: 0.4))
  #expect(anchor.incomingHandle == VectorPoint(x: 0.5, y: 0.4))
  #expect(anchor.outgoingHandle == VectorPoint(x: 0.7, y: 0.4))

  // Without a canvas size there is no fraction to convert into.
  var unresolved = stack
  unresolved.canvas = .unresolved
  #expect(unresolved.translating(layerID, byX: 100, y: -50) == unresolved)
}

@Test func aLayerFrameIsAnsweredInCanvasPixels() throws {
  let image = placedImage(x: 12, y: 34, width: 800, height: 600)
  let layer = ProjectLayer.image(image)
  var stack = canvasProject().applying(.addImageLayer(layer)).layerStack

  #expect(stack.frame(of: layer.id) == image.frame)

  // The canvas layer carries the document extent, and so does the RAW that
  // sized it: both are the whole canvas.
  #expect(stack.frame(of: .canvas) == LayerFrame(x: 0, y: 0, width: 1920, height: 1080))

  // An empty vector layer has no geometry to outline yet.
  let vectorLayerID = stack.ensureActiveVectorLayer()
  #expect(stack.frame(of: vectorLayerID) == nil)

  // Handles count: the control polygon contains the curve, so the box never
  // clips the artwork it stands for.
  stack.appendPath(
    VectorPath(
      anchors: [
        VectorAnchor(
          position: VectorPoint(x: 0.25, y: 0.5),
          outgoingHandle: VectorPoint(x: 0.2, y: 0.25)
        ),
        VectorAnchor(position: VectorPoint(x: 0.75, y: 0.5)),
      ]
    ),
    to: vectorLayerID
  )
  let vectorFrame = try #require(stack.frame(of: vectorLayerID))
  #expect(vectorFrame == LayerFrame(x: 384, y: 270, width: 1056, height: 270))

  #expect(stack.frame(of: ProjectLayerID()) == nil)
}
