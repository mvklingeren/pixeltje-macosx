import Foundation
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import PixeltjePipelineSDXSRuntime
import Testing

private actor ImageGenerationCounter {
  private(set) var count = 0
  private(set) var seeds: [String: Int64] = [:]
  func next() -> Int { count += 1; return count }
  func record(seed: Int64, for key: String) { seeds[key] = seed }
}

private actor AssetPreviewCollector {
  private(set) var previews: [PipelineAssetPreview] = []
  func record(_ progress: PipelineExecutionProgress) {
    if let preview = progress.assetPreview { previews.append(preview) }
  }
}

@Test func keyedImageCacheGeneratesOncePerRunAndLoadsByKey() async throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  func link(_ source: String, _ sourcePort: String,
    _ target: String, _ targetPort: String) -> PipelineConnection {
    .init(output: .init(nodeID: id(source), port: sourcePort),
      input: .init(nodeID: id(target), port: targetPort))
  }
  let kind = PipelineNodeKind(rawValue: "test.generatedImage")
  let document = PipelineDocument(
    id: .init(rawValue: "keyed-image-cache"), name: "Keyed image cache", mode: .generic,
    nodes: [
      PipelineNode(id: id("generator"), kind: kind),
      PipelineNode(id: id("store"), kind: .imageCache,
        parameters: ["key": .string("stone.top"), "mode": .string("store")]),
      PipelineNode(id: id("load"), kind: .imageCache,
        parameters: ["key": .string("stone.top"), "mode": .string("load")]),
      PipelineNode(id: id("output"), kind: .imageOutput),
    ], connections: [
      link("generator", "image", "store", "image"),
      link("load", "image", "output", "image"),
    ], primaryOutputNodeIDs: [id("output")])
  let counter = ImageGenerationCounter()
  let engine = PixeltjePipelineEngine(additionalNodeDescriptors: [
    .init(kind: kind, displayName: "Test Generator", category: "Test",
      outputs: [.init(name: "image", type: .image)]),
  ], additionalNodeExecutors: [
    .init(kind: kind) { _, _, _ in
      let count = await counter.next()
      let image = try PipelineImageInput(width: 1, height: 1,
        rgba: [Float(count) / 4, 0, 0, 1])
      return .init(outputs: ["image": PipelineNodeValue(image, type: .image)])
    },
  ])
  #expect(await engine.validate(document).isValid)
  var withoutStore = document
  withoutStore.nodes.removeAll { $0.id == id("store") }
  withoutStore.connections.removeAll { $0.input.nodeID == id("store") }
  #expect(!(await engine.validate(withoutStore)).isValid)
  let firstRun = UUID()
  let first = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(), traceRunID: firstRun)
  let second = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(), traceRunID: firstRun)
  #expect(first.image?.planarRGB == second.image?.planarRGB)
  #expect(await counter.count == 1)
  let next = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(), traceRunID: UUID())
  #expect(next.image?.planarRGB != first.image?.planarRGB)
  #expect(await counter.count == 2)
}

@Test func ashenPathGenerationWorkflowValidatesShaderAndCacheKeys() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  let document = try PipelineJSON.decode(Data(contentsOf: examples
    .appendingPathComponent("shader-ashen-path-3d-generation.pixpipeline.json")))
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeDescriptors: [SDXSPipelineFamily.descriptor()],
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
      + [SDXSPipelineFamily.executor(runner: SDXSPipelineRunner())])
  let report = await engine.validate(document, sourceMediaRoot: examples)
  #expect(report.isValid)
  #expect(!report.diagnostics.contains { $0.code == .disconnectedNode })
  #expect(!report.diagnostics.contains { $0.code == .shaderNotChecked })
}

@Test func ashenPathBakesThreeImagesBeforeFirstFrameAndReusesThem() async throws {
  let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples", isDirectory: true)
  var document = try PipelineJSON.decode(Data(contentsOf: examples
    .appendingPathComponent("shader-ashen-path-3d-generation.pixpipeline.json")))
  for index in document.nodes.indices {
    if document.nodes[index].id.rawValue == "primitive-int" {
      document.nodes[index].parameters["value"] = .integer(80)
    } else if document.nodes[index].id.rawValue == "primitive-int-2" {
      document.nodes[index].parameters["value"] = .integer(50)
    }
  }
  let counter = ImageGenerationCounter()
  let mock = PipelineNodeExecutor(kind: SDXSPipelineFamily.nodeKind) { node, inputs, context in
    _ = await counter.next()
    let seed = try #require(inputs["seed"]?.value(as: Int.self))
    await counter.record(seed: Int64(seed), for: node.id.rawValue)
    let red: Float = node.id.rawValue.contains("stone") ? 0.7 : 0.25
    let image = PipelineGeneratedImage(width: 8, height: 8,
      planarRGB: Array(repeating: red, count: 64)
        + Array(repeating: 0.3, count: 64)
        + Array(repeating: 0.2, count: 64),
      encoding: .sRGBZeroToOne,
      semanticPipelineSHA256: context.semanticSHA256)
    return .init(outputs: ["image": PipelineNodeValue(image, type: .image)])
  }
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeDescriptors: [SDXSPipelineFamily.descriptor()],
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors() + [mock])
  #expect((await engine.validate(document, sourceMediaRoot: examples)).isValid)
  let packageRoots = [SDXSPipelineFamily.packageID: examples]
  let runID = UUID()
  for call in 0..<2 {
    let result = try await engine.execute(document, sourceMediaRoot: examples,
      packageRootsByID: packageRoots,
      invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(Int64(call))]),
      traceRunID: runID)
    #expect(result.image?.width == 80)
  }
  #expect(await counter.count == 3)
  let seeds = await counter.seeds
  #expect(Set(seeds.values).count == 3)
  _ = try await engine.execute(document, sourceMediaRoot: examples,
    packageRootsByID: packageRoots,
    invocation: .init(values: [PipelineInvocation.loopCallIndexKey: .integer(0)]),
    traceRunID: UUID())
  #expect(await counter.count == 6)
}

@Test func assetCacheKeepsMixedImageAndAudioSlotsStableWithinRun() async throws {
  func id(_ value: String) -> PipelineNodeID { .init(rawValue: value) }
  func link(_ source: String, _ sourcePort: String,
    _ target: String, _ targetPort: String) -> PipelineConnection {
    .init(output: .init(nodeID: id(source), port: sourcePort),
      input: .init(nodeID: id(target), port: targetPort))
  }
  let imageKind = PipelineNodeKind(rawValue: "test.cacheImageSource")
  let audioKind = PipelineNodeKind(rawValue: "test.cacheAudioSource")
  let sinkKind = PipelineNodeKind(rawValue: "test.cacheBundleSink")
  let audioURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("pixeltje-cache-audio-\(UUID().uuidString).wav")
  defer { try? FileManager.default.removeItem(at: audioURL) }
  try Data("original".utf8).write(to: audioURL)
  let counter = ImageGenerationCounter()
  let document = PipelineDocument(id: .init(rawValue: "mixed-asset-cache"),
    name: "Mixed asset cache", mode: .generic,
    nodes: [
      PipelineNode(id: id("image"), kind: imageKind),
      PipelineNode(id: id("audio"), kind: audioKind),
      PipelineNode(id: id("cache"), kind: .assetCache,
        parameters: ["slotCount": .integer(2)]),
      PipelineNode(id: id("sink"), kind: sinkKind),
    ], connections: [
      link("image", "image", "cache", "asset0"),
      link("audio", "audio", "cache", "asset1"),
      link("cache", "assets", "sink", "assets"),
    ], primaryOutputNodeIDs: [id("sink")])
  let engine = PixeltjePipelineEngine(additionalNodeDescriptors: [
    .init(kind: imageKind, displayName: "Image", category: "Test",
      outputs: [.init(name: "image", type: .image)]),
    .init(kind: audioKind, displayName: "Audio", category: "Test",
      outputs: [.init(name: "audio", type: .audio)]),
    .init(kind: sinkKind, displayName: "Sink", category: "Test",
      inputs: [.init(name: "assets", type: .assetBundle)], isTerminal: true),
  ], additionalNodeExecutors: [
    .init(kind: imageKind) { _, _, _ in
      _ = await counter.next()
      return .init(outputs: ["image": PipelineNodeValue(
        try PipelineImageInput(width: 1, height: 1, rgba: [0.5, 0, 0, 1]),
        type: .image)])
    },
    .init(kind: audioKind) { _, _, _ in
      _ = await counter.next()
      return .init(outputs: ["audio": PipelineNodeValue(audioURL, type: .audio)])
    },
    .init(kind: sinkKind) { _, inputs, context in
      let bundle = try #require(inputs["assets"]?.value(as: PipelineAssetBundle.self))
      let image = try #require(bundle["asset0"]?.value(as: PipelineImageInput.self))
      let audio = try #require(bundle["asset1"]?.value(as: URL.self))
      let text = "\(image.rgba[0]):\(String(decoding: try Data(contentsOf: audio), as: UTF8.self))"
      return .init(terminalOutput: .plainText(.init(text: text,
        semanticPipelineSHA256: context.semanticSHA256)))
    },
  ])
  #expect((await engine.validate(document)).isValid)
  let run = UUID()
  let previews = AssetPreviewCollector()
  let first = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(), progress: { await previews.record($0) }, traceRunID: run)
  guard case .plainText(let firstText) = first else {
    Issue.record("Expected a text result")
    return
  }
  #expect(firstText.text == "0.5:original")
  let reported = await previews.previews
  #expect(reported.contains { $0.slot == "asset0" && $0.image?.width == 1 })
  #expect(reported.contains { $0.slot == "asset1" && $0.audioURL != nil })
  try Data("changed".utf8).write(to: audioURL)
  let second = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(), progress: { await previews.record($0) }, traceRunID: run)
  guard case .plainText(let secondText) = second else {
    Issue.record("Expected a text result")
    return
  }
  #expect(secondText.text == "0.5:original")
  #expect(await counter.count == 2)
  #expect(await previews.previews.count == reported.count)
  let next = try await engine.execute(document, packageRootsByID: [:],
    invocation: .init(), traceRunID: UUID())
  guard case .plainText(let nextText) = next else {
    Issue.record("Expected a text result")
    return
  }
  #expect(nextText.text == "0.5:changed")
  #expect(await counter.count == 4)

  var retainedDocument = document
  retainedDocument.nodes[2].parameters["keepBetweenRuns"] = .boolean(true)
  let retainedRun = UUID()
  let retainedPreviews = AssetPreviewCollector()
  _ = try await engine.execute(retainedDocument, packageRootsByID: [:],
    invocation: .init(), progress: { await retainedPreviews.record($0) },
    traceRunID: retainedRun)
  let retainedAudioCopy = try #require(await retainedPreviews.previews
    .first(where: { $0.slot == "asset1" })?.audioURL)
  await engine.endLiveMetalPreview(runID: retainedRun)
  #expect(FileManager.default.fileExists(atPath: retainedAudioCopy.path))
  // Editing the consumer changes the graph, not the cached inputs.
  retainedDocument.nodes[3].title = "Output after pause"
  try Data("new source".utf8).write(to: audioURL)
  let reused = try await engine.execute(retainedDocument, packageRootsByID: [:],
    invocation: .init(), traceRunID: UUID())
  guard case .plainText(let reusedText) = reused else {
    Issue.record("Expected a text result")
    return
  }
  #expect(reusedText.text == "0.5:changed")
  #expect(await counter.count == 6)

  retainedDocument.nodes[0].title = "Changed cache input"
  let changedInputPreviews = AssetPreviewCollector()
  let changedInput = try await engine.execute(retainedDocument, packageRootsByID: [:],
    invocation: .init(), progress: { await changedInputPreviews.record($0) },
    traceRunID: UUID())
  guard case .plainText(let changedInputText) = changedInput else {
    Issue.record("Expected a text result")
    return
  }
  #expect(changedInputText.text == "0.5:new source")
  #expect(await counter.count == 8)
  #expect(!FileManager.default.fileExists(atPath: retainedAudioCopy.path))
  let changedInputAudioCopy = try #require(await changedInputPreviews.previews
    .first(where: { $0.slot == "asset1" })?.audioURL)

  await engine.clearCachedAssets(for: id("cache"))
  #expect(!FileManager.default.fileExists(atPath: changedInputAudioCopy.path))
  let refreshed = try await engine.execute(retainedDocument, packageRootsByID: [:],
    invocation: .init(), traceRunID: UUID())
  guard case .plainText(let refreshedText) = refreshed else {
    Issue.record("Expected a text result")
    return
  }
  #expect(refreshedText.text == "0.5:new source")
  #expect(await counter.count == 10)

  retainedDocument.name = "Changed workflow revision"
  _ = try await engine.execute(retainedDocument, packageRootsByID: [:],
    invocation: .init(), traceRunID: UUID())
  #expect(await counter.count == 12)
}
