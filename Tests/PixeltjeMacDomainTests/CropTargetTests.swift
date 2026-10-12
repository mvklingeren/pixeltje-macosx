import Foundation
import PixeltjeMacDomain
import Testing

private func cropTargetImageLayer(
  id: ProjectLayerID = ProjectLayerID(rawValue: "crop-target-image"),
  frame: LayerFrame = LayerFrame(x: 20, y: 10, width: 160, height: 80)
) -> ProjectLayer {
  let source = SourceReference(
    originalFilename: "crop-target.png",
    linkedPath: "/tmp/crop-target.png",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 0, modificationDate: nil)
  )
  return ProjectLayer(
    id: id,
    name: "Crop target",
    content: .image(
      ImageLayer(source: source, frame: frame, naturalWidth: 160, naturalHeight: 80)
    )
  )
}

@Test func cropRectangleCanBeDrawnFreelyInEitherDirection() throws {
  let forward = CropGeometry.created(
    fromUnitX: 0.2,
    unitY: 0.3,
    toUnitX: 0.8,
    unitY: 0.9,
    like: CropRecipe(),
    imageWidth: 200,
    imageHeight: 100
  )
  #expect(abs(forward.left - 0.2) < 1e-9)
  #expect(abs(forward.bottom - 0.3) < 1e-9)
  #expect(abs(forward.right - 0.8) < 1e-9)
  #expect(abs(forward.top - 0.9) < 1e-9)

  let reverse = CropGeometry.created(
    fromUnitX: 0.8,
    unitY: 0.9,
    toUnitX: 0.2,
    unitY: 0.3,
    like: CropRecipe(),
    imageWidth: 200,
    imageHeight: 100
  )
  #expect(abs(reverse.left - 0.2) < 1e-9)
  #expect(abs(reverse.bottom - 0.3) < 1e-9)
  #expect(abs(reverse.right - 0.8) < 1e-9)
  #expect(abs(reverse.top - 0.9) < 1e-9)
}

@Test func drawnRectangleHonorsTheSelectedAspectRatio() throws {
  let crop = CropGeometry.created(
    fromUnitX: 0.15,
    unitY: 0.2,
    toUnitX: 0.65,
    unitY: 0.8,
    like: CropRecipe(aspectRatio: .ratio(width: 1, height: 1)),
    imageWidth: 200,
    imageHeight: 100
  )
  let aspect = try #require(
    CropGeometry.pixelAspect(crop, imageWidth: 200, imageHeight: 100)
  )
  #expect(abs(aspect - 1) < 1e-9)
}

@Test func layerCropIsStoredOnOnlyTheChosenLayerAndRoundTrips() throws {
  let imageID = ProjectLayerID(rawValue: "cropped-image")
  let otherID = ProjectLayerID(rawValue: "uncropped-image")
  let canvas = CanvasRecipe(width: 200, height: 100)
  let recipe = ProjectRecipe(
    layerStack: LayerStackRecipe(
      layers: [
        cropTargetImageLayer(id: imageID),
        cropTargetImageLayer(id: otherID, frame: LayerFrame(x: 0, y: 0, width: 50, height: 50)),
        .canvasBase(canvas),
      ],
      activeLayerID: imageID
    )
  )
  let crop = CropRecipe(left: 0.25, bottom: 0.1, right: 0.75, top: 0.9)

  let cropped = recipe.applying(.setLayerCrop(imageID, crop, actionName: "Crop Layer"))
  #expect(cropped.layerStack.layer(id: imageID)?.crop == crop)
  #expect(cropped.layerStack.layer(id: otherID)?.crop == nil)
  #expect(cropped.crop == recipe.crop)

  let decoded = try JSONDecoder().decode(
    ProjectRecipe.self,
    from: JSONEncoder().encode(cropped)
  )
  #expect(decoded.layerStack.layer(id: imageID)?.crop == crop)
  #expect(decoded.layerStack.layer(id: otherID)?.crop == nil)
}

@Test func appliedLayerCropShrinksTheLayerBoundsWithoutTouchingItsPixels() throws {
  let imageID = ProjectLayerID(rawValue: "bounded-crop-image")
  let recipe = ProjectRecipe(
    layerStack: LayerStackRecipe(
      layers: [cropTargetImageLayer(id: imageID), .canvasBase(CanvasRecipe(width: 200, height: 100))],
      activeLayerID: imageID
    )
  )
  let authored = LayerFrame(x: 20, y: 10, width: 160, height: 80)
  let crop = CropRecipe(left: 0.25, bottom: 0.125, right: 0.75, top: 0.875)

  let cropped = recipe.applying(.setLayerCrop(imageID, crop, actionName: "Crop Layer"))
  let stack = cropped.layerStack

  // The layer now occupies only what its crop keeps.
  #expect(stack.frame(of: imageID) == LayerFrame(x: 60, y: 20, width: 80, height: 60))
  // Its placement and the rectangle the crop is measured in are untouched, so
  // the hidden pixels remain available to the Crop tool.
  #expect(stack.layer(id: imageID)?.imageLayer?.frame == authored)
  #expect(stack.cropFrame(of: imageID) == authored)
  #expect(stack.uncroppedFrame(of: imageID) == authored)
  #expect(stack.canCropLayer(imageID))

  // Widening the crop back to the full frame restores the original bounds.
  let restored = cropped.applying(.setLayerCrop(imageID, .identity, actionName: "Crop Layer"))
  #expect(restored.layerStack.frame(of: imageID) == authored)
}

@Test func croppedLayerKeepsItsWindowWhenMovedOrScaled() throws {
  let imageID = ProjectLayerID(rawValue: "transformed-crop-image")
  let authored = LayerFrame(x: 20, y: 10, width: 160, height: 80)
  let cropped = ProjectRecipe(
    layerStack: LayerStackRecipe(
      layers: [cropTargetImageLayer(id: imageID), .canvasBase(CanvasRecipe(width: 200, height: 100))],
      activeLayerID: imageID
    )
  ).applying(
    .setLayerCrop(
      imageID,
      CropRecipe(left: 0.25, bottom: 0.125, right: 0.75, top: 0.875),
      actionName: "Crop Layer"
    ))

  // The crop is applied before the transform, so the window travels with the
  // content rather than staying where it was on the canvas.
  let moved = cropped.applying(.translateLayer(imageID, byX: 10, y: 5))
  #expect(moved.layerStack.frame(of: imageID) == LayerFrame(x: 70, y: 25, width: 80, height: 60))
  #expect(
    moved.layerStack.uncroppedFrame(of: imageID)
      == LayerFrame(x: 30, y: 15, width: 160, height: 80))

  let scaled = cropped.applying(
    .setLayerTransform(imageID, LayerTransform(referenceRect: authored, scaleX: 2, scaleY: 2)))
  #expect(
    scaled.layerStack.frame(of: imageID) == LayerFrame(x: 20, y: -10, width: 160, height: 120))
  #expect(
    scaled.layerStack.uncroppedFrame(of: imageID)
      == LayerFrame(x: -60, y: -30, width: 320, height: 160))
}

@Test func lockedPrimaryRawCanStillBeCroppedAsALayer() throws {
  var stack = LayerStackRecipe.initialRawBackground()
  stack.canvas = CanvasRecipe(width: 300, height: 200)
  let recipe = ProjectRecipe(layerStack: stack)
  let crop = CropRecipe(left: 0.1, bottom: 0.2, right: 0.9, top: 0.8)

  #expect(recipe.layerStack.layer(id: .rawBackground)?.isLocked == true)
  #expect(recipe.layerStack.canCropLayer(.rawBackground))

  let cropped = recipe.applying(
    .setLayerCrop(.rawBackground, crop, actionName: "Crop RAW Layer"))
  #expect(cropped.layerStack.layer(id: .rawBackground)?.crop == crop)
  #expect(cropped.layerStack.canvas == stack.canvas)
  #expect(cropped.crop.isFullFrame)
}

@Test func canvasCropReframesTheCanvasAndItsContent() throws {
  let imageID = ProjectLayerID(rawValue: "canvas-crop-image")
  let canvas = CanvasRecipe(width: 200, height: 100)
  let recipe = ProjectRecipe(
    layerStack: LayerStackRecipe(
      layers: [cropTargetImageLayer(id: imageID), .canvasBase(canvas)],
      activeLayerID: imageID
    )
  )
  let crop = CropRecipe(
    left: 0.25,
    bottom: 0.2,
    right: 0.75,
    top: 0.8,
    aspectRatio: .ratio(width: 5, height: 3),
    overlay: .grid
  )

  let cropped = recipe.applying(.cropCanvas(crop, actionName: "Crop Canvas"))

  #expect(cropped.layerStack.canvas == CanvasRecipe(width: 100, height: 60))
  #expect(
    cropped.layerStack.layer(id: imageID)?.imageLayer?.frame
      == LayerFrame(x: -30, y: -10, width: 160, height: 80)
  )
  #expect(cropped.crop.isFullFrame)
  #expect(cropped.crop.aspectRatio == crop.aspectRatio)
  #expect(cropped.crop.overlay == .grid)
}
