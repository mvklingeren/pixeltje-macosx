import Foundation
import Metal
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import simd
import Testing

private func geometryParameters(_ kind: PipelineNodeKind, _ values: [String: PipelineValue] = [:])
  -> PipelineGeometryParameters {
  .init(node: PipelineNode(id: .init(rawValue: "test"), kind: kind, parameters: values))
}

private func cubeExample() throws -> PipelineDocument {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try PipelineJSON.decode(Data(contentsOf: root.appendingPathComponent("Examples/render-cube.json")))
}

private func sdfPrimitivesExample() throws -> PipelineDocument {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try PipelineJSON.decode(Data(contentsOf:
    root.appendingPathComponent("Examples/shadertoy-sdf-primitives.pixpipeline.json")))
}

private func seascapeExample() throws -> PipelineDocument {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try PipelineJSON.decode(Data(contentsOf:
    root.appendingPathComponent("Examples/shadertoy-seascape.pixpipeline.json")))
}

private func heartsExample() throws -> PipelineDocument {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try PipelineJSON.decode(Data(contentsOf:
    root.appendingPathComponent("Examples/shader-plush-hearts.pixpipeline.json")))
}

private var shaderExampleRoot: URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Examples", isDirectory: true)
}

private actor MetalPreviewRecorder {
  var images: [PipelineGeneratedImage] = []
  func append(_ progress: PipelineExecutionProgress) {
    if let image = progress.preview, progress.previewNodeID?.rawValue == "render" {
      images.append(image)
    }
  }
}

@Test func metalRenderDimensionsUseOverflowChecksInsteadOfFixedCaps() throws {
  let size = try PipelineMetalRenderSize(width: 9000, height: 9000)
  #expect(size.pixels == 81_000_000)
  #expect(try geometryParameters(.cameraMatrices,
    ["width": .integer(9000)]).dimension("width") == 9000)
  let state = try PipelineMetalShaderState(json:
    #"{"version":1,"mode":"shader","fragmentFunction":"sdfPrimitivesFragment","width":9000,"height":9000}"#)
  #expect(state.width == 9000 && state.height == 9000)
  #expect(throws: (any Error).self) {
    try PipelineMetalRenderSize(width: 0, height: 10)
  }
  #expect(throws: (any Error).self) {
    try PipelineMetalRenderSize(width: Int.max, height: 2)
  }
}

@Test func workflowValidationCompilesLiteralMetalShaders() async throws {
  var hearts = try heartsExample()
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  let valid = await engine.validate(hearts, sourceMediaRoot: shaderExampleRoot)
  #expect(valid.isValid)
  #expect(!valid.diagnostics.contains { $0.code == .shaderNotChecked })

  let sourceIndex = try #require(hearts.nodes.firstIndex { $0.id.rawValue == "shader-text" })
  hearts.nodes[sourceIndex].parameters["value"] = .string(
    "#include <metal_stdlib>\nfragment float4 furryHeartsFragment() { return nope; }")
  let syntaxError = await engine.validate(hearts, sourceMediaRoot: shaderExampleRoot)
  #expect(syntaxError.errors.contains {
    $0.code == .invalidShader && $0.nodeID?.rawValue == "render"
  })

  hearts.nodes[sourceIndex].parameters["value"] = .string("""
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 fullscreenVertex(uint id [[vertex_id]]) {
      return float4(0.0, 0.0, 0.0, 1.0);
    }
    fragment float4 otherFragment() { return float4(1.0); }
    """)
  let missingEntryPoint = await engine.validate(hearts, sourceMediaRoot: shaderExampleRoot)
  #expect(missingEntryPoint.errors.contains { $0.code == .invalidShader })

  var fileShader = try heartsExample()
  let fileIndex = try #require(fileShader.nodes.firstIndex { $0.id.rawValue == "shader-text" })
  fileShader.nodes[fileIndex].parameters["value"] = .string("missing.metal")
  let renderID = PipelineNodeID(rawValue: "render")
  let sourceID = PipelineNodeID(rawValue: "shader-text")
  fileShader.connections.removeAll {
    $0.input.nodeID == renderID && $0.input.port == "source"
  }
  fileShader.connections.append(.init(
    output: .init(nodeID: sourceID, port: "value"),
    input: .init(nodeID: renderID, port: "sourceFile")))
  let missingFile = await engine.validate(fileShader, sourceMediaRoot: shaderExampleRoot)
  #expect(missingFile.errors.contains { $0.code == .invalidShader })
}

@Test func sdfShaderExampleUsesStateAndRendersChangingFrames() async throws {
  let savedExample = try sdfPrimitivesExample()
  #expect(try PipelineJSON.decode(PipelineJSON.encode(savedExample)) == savedExample)
  var document = savedExample
  document.connections.removeAll {
    $0.input.nodeID.rawValue == "render" && ["width", "height"].contains($0.input.port)
  }
  let stateIndex = try #require(document.nodes.firstIndex { $0.id.rawValue == "state" })
  var state = try #require(document.nodes[stateIndex].parameters["initialState"]?.stringValue)
  state = try PipelineStateJSON.setting(state, key: "width", to: .integer(96))
  state = try PipelineStateJSON.setting(state, key: "height", to: .integer(54))
  document.nodes[stateIndex].parameters["initialState"] = .string(state)
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect(await engine.validate(document).isValid)
  var missingShaderState = document
  missingShaderState.connections.removeAll {
    $0.input.nodeID.rawValue == "render" && $0.input.port == "state"
  }
  #expect(!(await engine.validate(missingShaderState)).isValid)
  var missingShaderFile = document
  missingShaderFile.connections.removeAll {
    $0.input.nodeID.rawValue == "render" && $0.input.port == "sourceFile"
  }
  #expect(!(await engine.validate(missingShaderFile)).isValid)
  let recorder = MetalPreviewRecorder()
  func frame(_ index: Int64, pointerX: Double? = nil,
    pointerY: Double? = nil) async throws -> PipelineGeneratedImage {
    var values: [String: PipelineInvocationValue] = [
      PipelineInvocation.loopCallIndexKey: .integer(index)
    ]
    if let pointerX { values[PipelineInvocation.trackpadXKey] = .number(pointerX) }
    if let pointerY { values[PipelineInvocation.trackpadYKey] = .number(pointerY) }
    let result = try await engine.execute(document, sourceMediaRoot: shaderExampleRoot,
      packageRootsByID: [:],
      invocation: .init(values: values), progress: { await recorder.append($0) })
    guard case .image(let image) = result else {
      throw PipelineEngineError.invalidInvocation("Expected shader image output.")
    }
    return image
  }
  let first = try await frame(0)
  let second = try await frame(15)
  let movedPointer = try await frame(0, pointerX: 0.1, pointerY: 0.8)
  #expect(first.width == 96 && first.height == 54)
  #expect(first.alpha?.allSatisfy { $0 == 1 } ?? true)
  #expect(first.planarRGB.allSatisfy { $0.isFinite && (0...1).contains($0) })
  #expect(first.planarRGB != second.planarRGB)
  #expect(first.planarRGB != movedPointer.planarRGB)
  #expect(Set(first.planarRGB).count > 16)
  let previews = await recorder.images
  #expect(previews.count == 3)
  #expect(previews.first?.planarRGB == first.planarRGB)
  let cardRecorder = MetalPreviewRecorder()
  let cardHints: [String: PipelineInvocationValue] = [
    PipelineInvocation.metalPreviewWidthKey: .integer(32),
    PipelineInvocation.metalPreviewHeightKey: .integer(20),
    PipelineInvocation.metalPreviewOnlyKey: .boolean(true),
  ]
  let cardResult = try await engine.execute(document, sourceMediaRoot: shaderExampleRoot,
    packageRootsByID: [:],
    invocation: .init(values: cardHints), progress: { await cardRecorder.append($0) })
  #expect(cardResult.image?.width == 32 && cardResult.image?.height == 20)
  let cardPreviews = await cardRecorder.images
  #expect(cardPreviews.count == 1)
  #expect(cardPreviews.first?.width == 32 && cardPreviews.first?.height == 20)

  let fullRecorder = MetalPreviewRecorder()
  var fullHints = cardHints
  fullHints[PipelineInvocation.metalPreviewOnlyKey] = .boolean(false)
  let fullResult = try await engine.execute(document, sourceMediaRoot: shaderExampleRoot,
    packageRootsByID: [:],
    invocation: .init(values: fullHints), progress: { await fullRecorder.append($0) })
  #expect(fullResult.image?.width == 96 && fullResult.image?.height == 54)
  let fullPreviews = await fullRecorder.images
  #expect(fullPreviews.count == 1)
  #expect(fullPreviews.first?.width == 32 && fullPreviews.first?.height == 20)
  #expect(throws: (any Error).self) {
    try PipelineMetalShaderState(json: #"{"version":1,"mode":"shader","fragmentFunction":"bad name","width":96,"height":54}"#)
  }
  #expect(throws: (any Error).self) {
    try PipelineMetalShaderState(json: #"{"version":2,"mode":"shader","fragmentFunction":"sdfPrimitivesFragment","width":96,"height":54}"#)
  }
  let defaultResult = try await engine.execute(savedExample,
    sourceMediaRoot: shaderExampleRoot,
    packageRootsByID: [:], invocation: .init())
  guard case .image(let defaultFrame) = defaultResult else {
    throw PipelineEngineError.invalidInvocation("Expected the example's default image output.")
  }
  #expect(defaultFrame.width == 2880 && defaultFrame.height == 1864)
  #expect(Set(defaultFrame.planarRGB).count > 16)

  var resized = document
  let widthID = PipelineNodeID(rawValue: "override-width")
  let heightID = PipelineNodeID(rawValue: "override-height")
  let renderID = PipelineNodeID(rawValue: "render")
  resized.nodes.append(.init(id: widthID, kind: .primitiveInt,
    parameters: ["value": .integer(128)]))
  resized.connections.append(.init(output: .init(nodeID: widthID, port: "value"),
    input: .init(nodeID: renderID, port: "width")))
  #expect(await engine.validate(resized).isValid)
  let widthResult = try await engine.execute(resized, sourceMediaRoot: shaderExampleRoot,
    packageRootsByID: [:], invocation: .init())
  #expect(widthResult.image?.width == 128)
  #expect(widthResult.image?.height == 54)

  resized.nodes.append(.init(id: heightID, kind: .primitiveInt,
    parameters: ["value": .integer(72)]))
  resized.connections.append(.init(output: .init(nodeID: heightID, port: "value"),
    input: .init(nodeID: renderID, port: "height")))
  #expect(await engine.validate(resized).isValid)
  let sizeResult = try await engine.execute(resized, sourceMediaRoot: shaderExampleRoot,
    packageRootsByID: [:], invocation: .init())
  #expect(sizeResult.image?.width == 128)
  #expect(sizeResult.image?.height == 72)

  let widthIndex = try #require(resized.nodes.firstIndex { $0.id == widthID })
  let heightIndex = try #require(resized.nodes.firstIndex { $0.id == heightID })
  resized.nodes[widthIndex].parameters["value"] = .integer(2880)
  resized.nodes[heightIndex].parameters["value"] = .integer(1864)
  let nativeResult = try await engine.execute(resized, sourceMediaRoot: shaderExampleRoot,
    packageRootsByID: [:], invocation: .init())
  #expect(nativeResult.image?.width == 2880)
  #expect(nativeResult.image?.height == 1864)
}

@Test func liveMetalPreviewAdvancesShaderTimeWithoutAnotherGraphCall() async throws {
  var document = try sdfPrimitivesExample()
  document.connections.removeAll {
    $0.input.nodeID.rawValue == "render"
      && ["width", "height", "sourceFile"].contains($0.input.port)
  }
  let stateIndex = try #require(document.nodes.firstIndex { $0.id.rawValue == "state" })
  document.nodes[stateIndex].parameters["initialState"] = .string(
    #"{"version":1,"mode":"shader","fragmentFunction":"flatTime","width":2,"height":2,"timeSeconds":0,"secondsPerFrame":0,"pointer":{"x":0.5,"y":0.5}}"#)
  document.nodes.removeAll { $0.id.rawValue == "shader-file" }
  let sourceID = PipelineNodeID(rawValue: "live-source")
  document.nodes.append(.init(id: sourceID, kind: .primitiveString,
    parameters: ["value": .string("""
      #include <metal_stdlib>
      using namespace metal;
      struct ShaderUniforms { float4 resolutionTime; float4 mouse; };
      vertex float4 fullscreenVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
      }
      fragment float4 flatTime(float4 position [[position]],
        constant ShaderUniforms &uniforms [[buffer(0)]]) {
        return float4(uniforms.resolutionTime.z * 0.5, 0.0, 0.0, 1.0);
      }
      """)]))
  document.connections.append(.init(
    output: .init(nodeID: sourceID, port: "value"),
    input: .init(nodeID: .init(rawValue: "render"), port: "source")))
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect(await engine.validate(document).isValid)
  let runID = UUID()
  await engine.beginLiveMetalPreview(runID: runID,
    nodeID: .init(rawValue: "render"))
  #expect(try await engine.liveMetalPreview(runID: runID)?.width == nil)
  let output = try await engine.updateLiveMetalPreviewState(
    document, runID: runID, nodeID: .init(rawValue: "render"), packageRootsByID: [:],
    invocation: .init(values: [
      PipelineInvocation.loopCallIndexKey: .integer(0),
      PipelineInvocation.metalPreviewTimeStepKey: .number(1),
      PipelineInvocation.metalPreviewCallIntervalKey: .number(0.02),
    ]))
  #expect(output.image == nil)
  try await Task.sleep(for: .milliseconds(30))
  let interpolated = try #require(await engine.liveMetalPreview(runID: runID))
  #expect(interpolated.width == 2 && interpolated.height == 2)
  let device = try #require(MTLCreateSystemDefaultDevice())
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
  let texture = try #require(device.makeTexture(
    descriptor: descriptor, iosurface: interpolated.surface, plane: 0))
  var rgba = [Float16](repeating: 0, count: 16)
  rgba.withUnsafeMutableBytes {
    texture.getBytes($0.baseAddress!, bytesPerRow: 16,
      from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
  }
  #expect(abs(Float(rgba[0]) - 0.5) < 0.01)
  await engine.endLiveMetalPreview(runID: runID)
  #expect(try await engine.liveMetalPreview(runID: runID)?.width == nil)
}

@Test func seascapeTrackpadHoldsCameraUntilReset() async throws {
  var document = try seascapeExample()
  let stateIndex = try #require(document.nodes.firstIndex { $0.id.rawValue == "state" })
  var state = try #require(document.nodes[stateIndex].parameters["initialState"]?.stringValue)
  state = try PipelineStateJSON.setting(state, key: "width", to: .integer(64))
  state = try PipelineStateJSON.setting(state, key: "height", to: .integer(36))
  document.nodes[stateIndex].parameters["initialState"] = .string(state)
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect(await engine.validate(document).isValid)
  func frame(engaged: Bool, engagedAtCall: Int64) async throws -> PipelineGeneratedImage {
    let result = try await engine.execute(document, sourceMediaRoot: shaderExampleRoot,
      packageRootsByID: [:], invocation: .init(values: [
        PipelineInvocation.loopCallIndexKey: .integer(15),
        PipelineInvocation.trackpadEngagedKey: .boolean(engaged),
        PipelineInvocation.trackpadEngagedAtCallKey: .integer(engagedAtCall),
      ]))
    return try #require(result.image)
  }
  let animated = try await frame(engaged: false, engagedAtCall: 0)
  let held = try await frame(engaged: true, engagedAtCall: 0)
  let heldLater = try await frame(engaged: true, engagedAtCall: 8)
  let reset = try await frame(engaged: false, engagedAtCall: 0)
  #expect(animated.planarRGB != held.planarRGB)
  #expect(held.planarRGB != heldLater.planarRGB)
  #expect(animated.planarRGB == reset.planarRGB)
}

@Test func cubeGeometryHasFlatFaceNormalsAndRejectsMalformedData() throws {
  let example = try cubeExample()
  let text = try #require(example.nodes.first { $0.id.rawValue == "geometry" }?
    .parameters["value"]?.stringValue)
  let mesh = try PipelineMesh3D.decode(text)
  #expect(mesh.positions.count == 36)
  #expect(mesh.indices.count == 36)
  #expect(mesh.normals[0] == SIMD3(0, 0, 1))
  #expect(mesh.normals[6] == SIMD3(0, 0, -1))
  #expect(mesh.normals[12] == SIMD3(-1, 0, 0))
  #expect(mesh.normals[18] == SIMD3(1, 0, 0))
  #expect(mesh.normals[24] == SIMD3(0, 1, 0))
  #expect(mesh.normals[30] == SIMD3(0, -1, 0))
  let smooth = try PipelineMesh3D.decode(text, normalMode: "smooth")
  #expect(smooth.positions.count == 8)
  #expect(smooth.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-6 })
  for invalid in [
    "{}",
    #"{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"triangles":[[0,1,3]]}"#,
    #"{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"triangles":[[0,0,1]]}"#,
    #"{"vertices":[[0,0],[1,0,0],[0,1,0]],"triangles":[[0,1,2]]}"#,
    #"{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"triangles":[[0,1,2]],"normals":[[0,0,0],[0,0,1],[0,0,1]]}"#,
    #"{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"triangles":[[0,1,2]],"textureCoordinates":[[0,0]]}"#,
  ] {
    #expect(throws: (any Error).self) { try PipelineMesh3D.decode(invalid) }
  }
}

@Test func transformMatrixAppliesScaleThenRotationThenTranslation() throws {
  let transform = try PipelineGeometryNodes.transform(geometryParameters(.transformMatrix, [
    "translationX": .number(3), "rotationZ": .number(90), "scaleX": .number(2),
  ]))
  let point = transform.value * SIMD4<Float>(1, 0, 0, 1)
  #expect(simd_distance(point, SIMD4(3, 2, 0, 1)) < 1e-5)
  let identity = try PipelineGeometryNodes.transform(geometryParameters(.transformMatrix))
  #expect(identity.value == matrix_identity_float4x4)
  #expect(throws: (any Error).self) {
    try PipelineGeometryNodes.transform(geometryParameters(.transformMatrix, ["scaleX": .number(0)]))
  }
  #expect(throws: (any Error).self) {
    try PipelineMatrix4x4(simd_float4x4(diagonal: SIMD4(repeating: .infinity)))
  }
}

@Test func cameraMatricesMapCameraOriginAndMetalDepthCorrectly() throws {
  for mode in ["perspective", "orthographic"] {
    let camera = try PipelineGeometryNodes.camera(geometryParameters(.cameraMatrices, [
      "positionX": .number(2), "positionY": .number(1), "positionZ": .number(4),
      "projection": .string(mode), "nearClip": .number(0.1), "farClip": .number(10),
      "width": .integer(800), "height": .integer(400),
    ]))
    let origin = camera.view.value * SIMD4<Float>(2, 1, 4, 1)
    #expect(simd_length(SIMD3(origin.x, origin.y, origin.z)) < 1e-6)
    for (z, expected) in [(Float(-0.1), Float(0)), (Float(-10), Float(1))] {
      let clip = camera.projection.value * SIMD4<Float>(0, 0, z, 1)
      #expect(abs(clip.z / clip.w - expected) < 1e-5)
    }
    #expect(abs(camera.projection.value[1][1] / camera.projection.value[0][0] - 2) < 1e-6)
  }
  for values: [String: PipelineValue] in [
    ["positionZ": .number(0)], ["upY": .number(0)],
    ["upY": .number(0), "upZ": .number(1)],
    ["nearClip": .number(100)], ["fieldOfView": .number(180)],
    ["projection": .string("unknown")],
  ] {
    #expect(throws: (any Error).self) {
      try PipelineGeometryNodes.camera(geometryParameters(.cameraMatrices, values))
    }
  }
}

@Test func cubeExampleRoundTripsAndSeparatesControlFromData() throws {
  let document = try cubeExample()
  #expect(try PipelineJSON.decode(PipelineJSON.encode(document)) == document)
  let report = PipelineGraphValidator.validate(document, registry: .coreAIV1,
    engineVersion: PixeltjePipelineEngine.currentEngineVersion)
  #expect(report.isValid)
  let loop = try #require(PipelineControlFlow.activeLoop(in: document, registry: .coreAIV1))
  #expect(loop.settings.maxCalls == 72)
  #expect(loop.settings.autoRepeat)
  #expect(loop.settings.delayMilliseconds == 33)
  #expect(loop.settings.autoPause == false)
  let timeline = try #require(document.nodes.first { $0.id.rawValue == "timeline" })
  let settings = try #require(PipelineTimelineSettings(node: timeline))
  #expect(settings.frameCount == 72)
  #expect(settings.tracks.first?.interpolation == .easeInOut)
  #expect(try PipelineGraphTopology.orderedNodeIDs(in: document).count == document.nodes.count)
  var invalid = document
  let index = try #require(invalid.connections.firstIndex { $0.input.port == "worldMatrix" })
  invalid.connections[index].output = .init(nodeID: .init(rawValue: "mesh"), port: "mesh")
  #expect(!PipelineGraphValidator.validate(invalid, registry: .coreAIV1,
    engineVersion: PixeltjePipelineEngine.currentEngineVersion).isValid)
}

private actor CubePreviewRecorder {
  var images: [PipelineGeneratedImage] = []
  func append(_ progress: PipelineExecutionProgress) {
    if let image = progress.preview, progress.previewNodeID?.rawValue == "preview" {
      images.append(image)
    }
  }
}

@Test func spinningCubeRendersDifferentFramesThroughExistingPreviewAndOutput() async throws {
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  var document = try cubeExample()
  for index in document.nodes.indices where ["width", "height"].contains(document.nodes[index].id.rawValue) {
    document.nodes[index].parameters["value"] = .integer(96)
  }
  let recorder = CubePreviewRecorder()
  func frame(_ index: Int64) async throws -> PipelineGeneratedImage {
    let result = try await engine.execute(document, packageRootsByID: [:],
      invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(index)]),
      progress: { await recorder.append($0) })
    guard case .image(let image) = result else {
      throw PipelineEngineError.invalidInvocation("Expected a cube image.")
    }
    return image
  }
  let first = try await frame(0)
  let second = try await frame(7)
  let loop = try #require(PipelineControlFlow.activeLoop(in: document, registry: .coreAIV1))
  #expect(loop.settings.callIndex(forRunCall: 73) == 0)
  let repeatFirst = try await frame(Int64(loop.settings.callIndex(forRunCall: 73)))
  #expect(first.width == 96 && first.height == 96)
  #expect(first.planarRGB != second.planarRGB)
  #expect(first.alpha != second.alpha)
  #expect(first.planarRGB == repeatFirst.planarRGB)
  #expect(first.alpha == repeatFirst.alpha)
  #expect(first.planarRGB.allSatisfy { $0.isFinite && (0...1).contains($0) })
  let alpha = try #require(first.alpha)
  #expect(alpha.first == 0)
  #expect(alpha[48 * 96 + 48] == 1)
  #expect(alpha.contains { $0 > 0 && $0 < 1 })
  let previews = await recorder.images
  #expect(previews.count == 3)
  #expect(previews.first?.alpha == first.alpha)
  #expect(previews.first?.planarRGB == first.planarRGB)

  // The same mesh and matrix payloads must survive existing polymorphic nodes.
  let meshLink = try #require(document.connections.firstIndex { $0.input.port == "mesh" })
  document.nodes.append(.init(id: .init(rawValue: "reroute"), kind: .reroute))
  document.connections.append(.init(output: document.connections[meshLink].output,
    input: .init(nodeID: .init(rawValue: "reroute"), port: "value")))
  document.connections[meshLink].output = .init(nodeID: .init(rawValue: "reroute"), port: "value")
  #expect(try await frame(0).planarRGB == first.planarRGB)
}

@Test func metalMeshRendererUsesDepthClippingCoverageAndInverseTransposeNormals() async throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let renderer = PipelineMeshRenderer(commandQueue: queue)
  let camera = try PipelineGeometryNodes.camera(geometryParameters(.cameraMatrices))
  let mesh = try PipelineMesh3D.decode(#"{"vertices":[[-1,-1,0.5],[1,-1,0.5],[0,1,0.5],[-1,-1,-0.5],[1,-1,-0.5],[0,1,-0.5]],"triangles":[[0,1,2],[3,4,5]],"normals":[[0,0,1],[0,0,1],[0,0,1],[0,0,-1],[0,0,-1],[0,0,-1]]}"#)
  let node = PipelineNode(id: .init(rawValue: "render"), kind: .renderMetal,
    parameters: ["width": .integer(64), "height": .integer(64),
      "color": .string("#FFFFFF"), "ambient": .number(0), "lightIntensity": .number(1),
      "lightX": .number(0), "lightY": .number(0), "lightZ": .number(1)])
  var inputs: [String: PipelineNodeValue] = [
    "mesh": .init(mesh, type: .mesh3D),
    "viewMatrix": .init(camera.view, type: .matrix4x4),
    "projectionMatrix": .init(camera.projection, type: .matrix4x4),
  ]
  let executor = PipelineMeshRenderer.executor(renderer: renderer)
  // Only the context's public fields used by the executor need meaningful values.
  let context = PipelineNodeExecutionContext(semanticSHA256: "test", invocation: .init(),
    sourceMediaRoot: nil, packageRootsByID: [:], nodeIndex: 0, nodeCount: 1, progress: { _ in })
  let result = try await executor.execute(node, inputs: inputs, context: context)
  let image = try #require(result.outputs["image"]?.value(as: PipelineImageInput.self))
  let mask = try #require(result.outputs["mask"]?.value(as: PipelineMaskInput.self))
  let center = 32 * 64 + 32
  #expect(image.rgba[center * 4] > 0.99) // The later, dark rear triangle cannot overwrite the front.
  #expect(mask.coverage[center] == 1)
  #expect(mask.coverage[0] == 0)
  #expect(image.rgba[3] == 0)
  #expect(mask.coverage == stride(from: 3, to: image.rgba.count, by: 4).map { image.rgba[$0] })
  var wireframe = node
  wireframe.parameters["mode"] = .string("wireframe")
  let wire = try await executor.execute(wireframe, inputs: inputs, context: context)
  let wireMask = try #require(wire.outputs["mask"]?.value(as: PipelineMaskInput.self))
  #expect(wireMask.coverage.reduce(0, +) < mask.coverage.reduce(0, +))
  inputs["worldMatrix"] = .init(try PipelineGeometryNodes.transform(
    geometryParameters(.transformMatrix, ["translationZ": .number(6)])), type: .matrix4x4)
  let clipped = try await executor.execute(node, inputs: inputs, context: context)
  #expect(clipped.outputs["mask"]?.value(as: PipelineMaskInput.self)?.coverage.allSatisfy { $0 == 0 } == true)

  let angled = try PipelineMesh3D.decode(#"{"vertices":[[-1,-1,0],[1,-1,0],[0,1,0]],"triangles":[[0,1,2]],"normals":[[1,1,0],[1,1,0],[1,1,0]]}"#)
  inputs["mesh"] = .init(angled, type: .mesh3D)
  inputs["worldMatrix"] = .init(try PipelineGeometryNodes.transform(
    geometryParameters(.transformMatrix, ["scaleX": .number(2)])), type: .matrix4x4)
  var lightX = node
  lightX.parameters["lightX"] = .number(1)
  lightX.parameters["lightZ"] = .number(0)
  let scaled = try await executor.execute(lightX, inputs: inputs, context: context)
  let lit = try #require(scaled.outputs["image"]?.value(as: PipelineImageInput.self))
  #expect((0.69...0.71).contains(lit.rgba[center * 4]))
}
