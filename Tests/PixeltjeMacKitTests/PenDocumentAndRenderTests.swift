import CoreGraphics
import CoreImage
import PixeltjeMacDomain
import Testing

@testable import PixeltjeMacKit

@MainActor
@Test func documentUndoRedoRestoresExactVectorState() throws {
  let document = ProjectDocument()
  let before = document.editorModel.recipe
  var stack = before.layerStack
  let layerID = stack.ensureActiveVectorLayer()
  let path = VectorPath(anchors: [
    VectorAnchor(
      position: VectorPoint(x: 0.123_456_789, y: 0.987_654_321),
      incomingHandle: VectorPoint(x: 0.1, y: 0.9),
      outgoingHandle: VectorPoint(x: 0.2, y: 0.8),
      kind: .smooth
    )
  ])
  stack.appendPath(path, to: layerID)

  document.perform(.setLayerStack(stack, actionName: "Add Anchor"), interactive: false)
  #expect(document.editorModel.recipe.layerStack == stack)
  document.undoManager?.undo()
  #expect(document.editorModel.recipe == before)
  document.undoManager?.redo()
  #expect(document.editorModel.recipe.layerStack == stack)
}

@MainActor
@Test func projectPackageSaveAndReopenPreservesVectorPaths() throws {
  let source = SourceReference(
    originalFilename: "fixture.dng",
    linkedPath: "/tmp/fixture.dng",
    securityScopedBookmark: nil,
    fingerprint: SourceFingerprint(byteLength: 42, modificationDate: nil)
  )
  let document = ProjectDocument()
  document.editorModel.replaceRecipe(ProjectRecipe(source: source))
  var stack = document.editorModel.recipe.layerStack
  let layerID = stack.ensureActiveVectorLayer()
  let path = VectorPath(
    anchors: [
      VectorAnchor(position: VectorPoint(x: 0.125, y: 0.25)),
      VectorAnchor(
        position: VectorPoint(x: 0.75, y: 0.875),
        incomingHandle: VectorPoint(x: 0.6, y: 0.7),
        outgoingHandle: VectorPoint(x: 0.85, y: 0.95),
        kind: .smooth
      ),
    ]
  )
  stack.appendPath(path, to: layerID)
  document.perform(.setLayerStack(stack, actionName: "Add Path"), interactive: false)

  let wrapper = try document.fileWrapper(ofType: ProjectDocument.projectTypeIdentifier)
  let reopened = ProjectDocument()
  try reopened.read(from: wrapper, ofType: ProjectDocument.projectTypeIdentifier)
  reopened.restoreLoadedState()

  #expect(reopened.editorModel.recipe == document.editorModel.recipe)
  #expect(reopened.editorModel.recipe.layerStack.path(id: path.id)?.path == path)
}

@Test func visibleVectorArtworkProducesPixelsAndHiddenArtworkDoesNot() throws {
  let raw = ProjectLayer.rawBase()
  let vectorLayer = ProjectLayer(
    name: "Vector Layer",
    zOrder: 1,
    content: .vector(
      VectorLayer(objects: [
        .path(
          VectorPath(
            anchors: [
              VectorAnchor(position: VectorPoint(x: 0.1, y: 0.5)),
              VectorAnchor(position: VectorPoint(x: 0.9, y: 0.5)),
            ],
            stroke: VectorStrokeStyle(
              color: VectorColor(red: 1, green: 0, blue: 0),
              width: 4
            )
          ))
      ]))
  )
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
  let visibleStack = LayerStack(layers: [raw, vectorLayer], activeLayerID: vectorLayer.id)
  let maybeCGImage = try VectorArtworkRenderer.makeCGImage(
    layerStack: visibleStack,
    width: 32,
    height: 32,
    workingColorSpace: colorSpace
  )
  let cgImage = try #require(maybeCGImage)
  // Vector artwork is materialized in the working space so gradients and EDR
  // values survive; an 8-bit intermediate would band and clip.
  #expect(cgImage.bitsPerComponent == 16)
  #expect(cgImage.bitmapInfo.contains(.floatComponents))
  #expect(cgImage.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)
  let providerData = try #require(cgImage.dataProvider?.data)
  let providerBytes = try #require(CFDataGetBytePtr(providerData))
  let providerMaximum = (0..<CFDataGetLength(providerData)).map { providerBytes[$0] }.max() ?? 0
  #expect(providerMaximum > 0)
  // The alpha channel is the last component of each pixel, whatever its depth.
  let bytesPerPixel = cgImage.bitsPerPixel / 8
  let alphaOffset = bytesPerPixel - cgImage.bitsPerComponent / 8
  let providerAlphaMaximum =
    stride(from: alphaOffset, to: CFDataGetLength(providerData), by: bytesPerPixel)
    .flatMap { offset in (0..<(cgImage.bitsPerComponent / 8)).map { providerBytes[offset + $0] } }
    .max() ?? 0
  #expect(providerAlphaMaximum > 0)
  let maybeImage = try VectorArtworkRenderer.makeImage(
    layerStack: visibleStack,
    width: 32,
    height: 32,
    workingColorSpace: colorSpace
  )
  let image = try #require(maybeImage)
  #expect(image.extent == CGRect(x: 0, y: 0, width: 32, height: 32))
  let pathBounds = VectorArtworkRenderer.makePath(
    vectorLayer.content.vectorValue!.paths[0],
    width: 32,
    height: 32
  ).boundingBox
  #expect(pathBounds.width > 0)

  var hidden = vectorLayer
  hidden.isVisible = false
  let hiddenStack = LayerStack(layers: [raw, hidden], activeLayerID: hidden.id)
  #expect(
    try VectorArtworkRenderer.makeImage(
      layerStack: hiddenStack,
      width: 32,
      height: 32,
      workingColorSpace: colorSpace
    ) == nil
  )
}
