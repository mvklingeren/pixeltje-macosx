import Foundation
import CryptoKit
import CoreVideo
import IOSurface
import Metal
import PixeltjePipelineDomain
import Synchronization

/// Per-call diagnostics for an opt-in editor performance log.
public struct PipelineGPUProgramPerformance: Encodable, Sendable {
  public var renderSeconds = 0.0
  public var cloneSeconds = 0.0
  public var commandWaitSeconds = 0.0
  public var gpuExecutionSeconds = 0.0
  public var gpuCommandCount = 0
  public var gpuTimedCommandCount = 0
  public var readbackSeconds = 0.0
  public var previewCopySeconds = 0.0
}

/// Bounded, declarative Metal passes. Workflow data names functions and fixed
/// resource bindings; only this actor allocates resources or submits commands.
actor PipelineGPUProgram {
  private struct Definition: Decodable {
    struct Resource: Decodable {
      let name: String
      let kind: String
      let bytes: Int?
      let input: String?
      let design: String?
      let weight: String?
      let strings: [String]?
    }
    struct Pass: Decodable {
      let kind: String
      let function: String?
      let vertex: String?
      let fragment: String?
      let target: String?
      let load: String?
      let blend: String?
      let threads: [Int]?
      let vertexCount: Int?
      let instanceCount: Int?
      let buffers: [String: String]?
      let textures: [String: String]?
      let vertexBuffers: [String: String]?
      let fragmentBuffers: [String: String]?
      let vertexTextures: [String: String]?
      let fragmentTextures: [String: String]?
    }
    struct AudioEvent: Decodable {
      let buffer: String
      let asset: String
    }
    let version: Int
    let resources: [Resource]
    let initialize: [Pass]
    let tick: [Pass]
    let present: [Pass]
    let swaps: [[String]]
    let output: String
    let sceneRequestBuffer: String?
    let audioEvents: [AudioEvent]?
    let parameters: [String]?
  }

  private struct Uniforms {
    var resolutionTime: SIMD4<Float>
    var frameSeed: SIMD4<UInt32>
    var parameters0: SIMD4<Float>
    var parameters1: SIMD4<Float>
    var parameters2: SIMD4<Float>
    var parameters3: SIMD4<Float>
    var pointer: SIMD4<Float>
    var movement: SIMD4<Float>
  }

  private enum Resource {
    case buffer(any MTLBuffer)
    case immutableBuffer(any MTLBuffer)
    case texture(any MTLTexture)
    case inputTexture(any MTLTexture)
  }

  private struct Identity: Equatable {
    let runID: UUID?
    let nodeID: PipelineNodeID
    let semanticSHA256: String
    let program: String
    let source: String
    let parameterJSON: String
    let width: Int
    let height: Int
    let seed: UInt64
    let framesPerSecond: Double
    let inputImageHashes: [String: String]
    let fontFingerprints: [String: String]
  }

  private struct Session {
    let identity: Identity
    var resources: [String: Resource]
    var nextFrame: Int
  }

  private struct Frame {
    let image: PipelineImageInput?
    let sceneRequest: Int64
  }

  private struct FontKey: Hashable {
    let design: String
    let weight: String
    let strings: [String]
  }

  private let queue: any MTLCommandQueue
  private var committed: [PipelineNodeID: Session] = [:]
  private var pending: [PipelineNodeID: Session] = [:]
  private var pendingAudioEvents: [PipelineNodeID: (runID: UUID?, urls: [URL])] = [:]
  private var committedAudioEvents: [URL] = []
  private var cachedLibrary: (source: String, library: any MTLLibrary)?
  private var computePipelines: [String: any MTLComputePipelineState] = [:]
  private var renderPipelines: [String: any MTLRenderPipelineState] = [:]
  private var liveRunID: UUID?
  private var liveNodeID: PipelineNodeID?
  private var liveFrame: PipelineMetalPreviewFrame?
  private var livePointer: (revision: UInt64, value: SIMD4<Float>, secondaryActionCount: Float)?
  private var lastLiveTickNanoseconds: UInt64?
  private var pendingLiveTickNanoseconds: UInt64?
  private var cachedAssetHashes: (bundleID: UUID, hashes: [String: String])?
  private var preparedFonts: [FontKey: PipelineSystemFont.Prepared] = [:]
  private var preparedFontOrder: [FontKey] = []
  private var fontBuffers: [String: any MTLBuffer] = [:]
  private var fontBufferOrder: [String] = []
  private var reusableSurfaces: [IOSurface] = []
  private var surfaceSize: (width: Int, height: Int)?
  private var allocatedSurfaceCount = 0
  private var performanceRunID: UUID?
  private var currentPerformance: PipelineGPUProgramPerformance?
  private nonisolated let completedPerformance = Mutex<(
    runID: UUID, sample: PipelineGPUProgramPerformance)?>(nil)

  init(commandQueue: any MTLCommandQueue) { queue = commandQueue }

  func setPerformanceCapture(runID: UUID?) {
    performanceRunID = runID
    currentPerformance = nil
    completedPerformance.withLock { $0 = nil }
  }

  nonisolated func takePerformance(runID: UUID) -> PipelineGPUProgramPerformance? {
    completedPerformance.withLock { completed in
      guard completed?.runID == runID else { return nil }
      defer { completed = nil }
      return completed?.sample
    }
  }

  static func executor(runner: PipelineGPUProgram) -> PipelineNodeExecutor {
    .init(kind: .gpuProgram) { node, inputs, context in
      let frame = try await runner.render(node: node, inputs: inputs,
        context: context, previewOnly: false)
      guard let image = frame.image else {
        throw PipelineEngineError.invalidInvocation("GPU Program produced no image.")
      }
      let pixels = image.width * image.height
      var planar = [Float](repeating: 0, count: pixels * 3)
      for index in 0..<pixels {
        if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
        for channel in 0..<3 {
          planar[channel * pixels + index] = image.rgba[index * 4 + channel]
        }
      }
      await context.progress(.init(stage: .generating,
        message: "GPU Program: frame ready",
        completedUnitCount: context.nodeIndex + 1,
        totalUnitCount: context.nodeCount,
        preview: .init(width: image.width, height: image.height,
          planarRGB: planar, encoding: .sRGBZeroToOne,
          semanticPipelineSHA256: context.semanticSHA256),
        previewNodeID: node.id, activeNodeIDs: [node.id]))
      return .init(outputs: [
        "image": PipelineNodeValue(image, type: .image),
        "sceneRequest": PipelineNodeValue(frame.sceneRequest, type: .integer),
      ])
    }
  }

  func commit(runID: UUID?) {
    let matching = pending.filter { $0.value.identity.runID == runID }
    for (nodeID, session) in matching {
      committed[nodeID] = session
      pending[nodeID] = nil
      if let event = pendingAudioEvents.removeValue(forKey: nodeID),
        event.runID == runID, liveRunID == runID {
        committedAudioEvents.append(contentsOf: event.urls)
      }
    }
    if !matching.isEmpty, liveRunID == runID, let pendingLiveTickNanoseconds {
      lastLiveTickNanoseconds = pendingLiveTickNanoseconds
    }
    pendingLiveTickNanoseconds = nil
  }

  func discard(runID: UUID?) {
    pending = pending.filter { $0.value.identity.runID != runID }
    pendingAudioEvents = pendingAudioEvents.filter { $0.value.runID != runID }
    pendingLiveTickNanoseconds = nil
  }

  func beginLivePreview(runID: UUID, nodeID: PipelineNodeID) {
    liveRunID = runID
    liveNodeID = nodeID
    liveFrame = nil
    livePointer = nil
    lastLiveTickNanoseconds = nil
    pendingLiveTickNanoseconds = nil
    committedAudioEvents = []
  }

  func updateLivePointer(runID: UUID, nodeID: PipelineNodeID,
    revision: UInt64, x: Double, y: Double, actionCount: Int,
    secondaryActionCount: Int = 0) {
    guard liveRunID == runID, liveNodeID == nodeID,
      revision > (livePointer?.revision ?? 0),
      x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
      (0...16_777_215).contains(actionCount),
      (0...16_777_215).contains(secondaryActionCount) else { return }
    livePointer = (revision, SIMD4(Float(x), Float(y), Float(actionCount), 0),
      Float(secondaryActionCount))
  }

  func endLivePreview(runID: UUID) {
    guard liveRunID == runID else { return }
    liveRunID = nil
    liveNodeID = nil
    liveFrame = nil
    livePointer = nil
    lastLiveTickNanoseconds = nil
    pendingLiveTickNanoseconds = nil
    committedAudioEvents = []
  }

  func takeLiveAudioEvents(runID: UUID) -> [URL] {
    guard liveRunID == runID else { return [] }
    defer { committedAudioEvents = [] }
    return committedAudioEvents
  }

  func livePreview(runID: UUID) -> PipelineMetalPreviewFrame? {
    liveRunID == runID ? liveFrame : nil
  }

  func captureLivePreview(node: PipelineNode, inputs: [String: PipelineNodeValue],
    context: PipelineNodeExecutionContext) async throws -> Int64 {
    guard let runID = context.runID, liveRunID == runID,
      liveNodeID != nil else {
      throw PipelineEngineError.invalidInvocation("GPU Program preview run is no longer active.")
    }
    let frame = try await render(node: node, inputs: inputs,
      context: context, previewOnly: true)
    return frame.sceneRequest
  }

  func validateLiteral(programJSON: String, source: String) async throws {
    guard programJSON.utf8.count <= 65_536,
      let data = programJSON.data(using: .utf8) else {
      throw PipelineEngineError.invalidInvocation("GPU Program JSON exceeds 64 KiB.")
    }
    let program = try JSONDecoder().decode(Definition.self, from: data)
    let size = try PipelineMetalRenderSize(width: 512, height: 512)
    try Self.validate(program, size: size, parameters: [:])
    let library = try await queue.device.makeLibrary(
      source: PipelineMetalEasing.resolving(source), options: nil)
    for pass in program.initialize + program.tick + program.present {
      let names = pass.kind == "compute" ? [pass.function!] : [pass.vertex!, pass.fragment!]
      for name in names where library.makeFunction(name: name) == nil {
        throw PipelineEngineError.invalidInvocation("GPU Program is missing Metal function \(name).")
      }
    }
  }

  private func render(node: PipelineNode, inputs: [String: PipelineNodeValue],
    context: PipelineNodeExecutionContext,
    previewOnly: Bool) async throws -> Frame {
    let renderStartedAt = DispatchTime.now().uptimeNanoseconds
    currentPerformance = performanceRunID != nil && context.runID == performanceRunID
      ? PipelineGPUProgramPerformance() : nil
    try Task.checkCancellation()
    guard let programJSON = inputs["program"]?.value(as: String.self),
      !programJSON.isEmpty, programJSON.utf8.count <= 65_536,
      let programData = programJSON.data(using: .utf8) else {
      throw PipelineEngineError.invalidInvocation("GPU Program needs a JSON program (at most 64 KiB).")
    }
    let definition: Definition
    do { definition = try JSONDecoder().decode(Definition.self, from: programData) }
    catch { throw PipelineEngineError.invalidInvocation("GPU Program JSON: \(error.localizedDescription)") }
    let width = try Self.dimension("width", node: node, inputs: inputs)
    let height = try Self.dimension("height", node: node, inputs: inputs)
    let size = try PipelineMetalRenderSize(width: width, height: height)
    let fps = inputs["framesPerSecond"]?.value(as: Double.self)
      ?? node.parameters["framesPerSecond"]?.numberValue ?? 60
    guard fps.isFinite, (1...240).contains(fps) else {
      throw PipelineEngineError.invalidInvocation("GPU Program frame rate must be 1–240 Hz.")
    }
    let seed: UInt64
    if let input = inputs["seed"] {
      guard let value = input.value(as: UInt64.self)
        ?? input.value(as: Int64.self).flatMap({ $0 >= 0 ? UInt64($0) : nil }) else {
        throw PipelineEngineError.invalidInvocation("GPU Program seed must be non-negative.")
      }
      seed = value
    } else {
      let value = node.parameters["seed"]?.integerValue ?? 1
      guard value >= 0 else {
        throw PipelineEngineError.invalidInvocation("GPU Program seed must be non-negative.")
      }
      seed = UInt64(value)
    }
    let parameterJSON = inputs["parameters"]?.value(as: String.self) ?? "{}"
    guard parameterJSON.utf8.count <= 16_384,
      let data = parameterJSON.data(using: .utf8),
      let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: NSNumber],
      dictionary.count <= 16 else {
      throw PipelineEngineError.invalidInvocation("GPU Program parameters must be a JSON object of at most 16 numbers.")
    }
    let pointerX = try Self.pointerCoordinate("pointerX", inputs: inputs)
    let pointerY = try Self.pointerCoordinate("pointerY", inputs: inputs)
    let actionCount = inputs["actionCount"]?.value(as: Double.self) ?? 0
    guard actionCount.isFinite, actionCount.rounded(.towardZero) == actionCount,
      (0...16_777_215).contains(actionCount) else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program action count must be an integer from 0 to 16,777,215.")
    }
    let pointer = SIMD4(Float(pointerX), Float(pointerY), Float(actionCount), 0)
    let secondaryActionCount = inputs["secondaryActionCount"]?.value(as: Double.self) ?? 0
    guard secondaryActionCount.isFinite,
      secondaryActionCount.rounded(.towardZero) == secondaryActionCount,
      (0...16_777_215).contains(secondaryActionCount) else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program secondary action count must be an integer from 0 to 16,777,215.")
    }
    let moveX = try Self.movementCoordinate("moveX", inputs: inputs)
    let moveY = try Self.movementCoordinate("moveY", inputs: inputs)
    let movement = SIMD4(Float(moveX), Float(moveY), Float(secondaryActionCount), 0)
    let source = try PipelineMeshRenderer.shaderSource(
      supplied: inputs["source"]?.value(as: String.self),
      fileName: inputs["sourceFile"]?.value(as: String.self),
      sourceMediaRoot: context.sourceMediaRoot)
    try Self.validate(definition, size: size, parameters: dictionary)
    let directPreview = previewOnly && Self.canRenderDirectlyToPreview(definition)
    var inputImages: [String: PipelineImageInput] = [:]
    var inputImageHashes: [String: String] = [:]
    let assets = inputs["assets"]?.value(as: PipelineAssetBundle.self)
    var audioAssets: [String: URL] = [:]
    for event in definition.audioEvents ?? [] {
      guard let value = assets?[event.asset], value.type == .audio,
        let url = value.value(as: URL.self)
          ?? value.value(as: PipelineGeneratedAudio.self)?.fileURL else {
        throw PipelineEngineError.invalidInvocation(
          "GPU Program needs audio asset \(event.asset).")
      }
      audioAssets[event.asset] = url
    }
    if let assets, let cachedAssetHashes, cachedAssetHashes.bundleID == assets.id {
      inputImageHashes = cachedAssetHashes.hashes
    }
    for resource in definition.resources where resource.kind == "inputTexture" {
      guard let port = resource.input,
        let value = assets?[port] else {
        throw PipelineEngineError.invalidInvocation(
          "GPU Program needs image asset \(resource.input ?? resource.name).")
      }
      let image: PipelineImageInput
      if let raster = value.value(as: PipelineImageInput.self) { image = raster }
      else if let generated = value.value(as: PipelineGeneratedImage.self) {
        image = try PipelineImageInput(generatedImage: generated)
      } else {
        throw PipelineEngineError.invalidInvocation("GPU Program image \(port) has no pixels.")
      }
      guard image.width <= 4096, image.height <= 4096,
        image.width * image.height <= 4_194_304 else {
        throw PipelineEngineError.invalidInvocation("GPU Program input images are limited to 4 megapixels.")
      }
      inputImages[port] = image
      if inputImageHashes[port] == nil {
        inputImageHashes[port] = image.rgba.withUnsafeBytes {
          SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined()
        }
      }
    }
    if let assets {
      cachedAssetHashes = (assets.id, inputImageHashes)
    }
    var fonts: [String: PipelineSystemFont.Prepared] = [:]
    var fontFingerprints: [String: String] = [:]
    for resource in definition.resources where resource.kind == "systemFont" {
      let key = FontKey(design: resource.design!, weight: resource.weight!,
        strings: resource.strings!)
      let prepared: PipelineSystemFont.Prepared
      if let cached = preparedFonts[key] { prepared = cached }
      else {
        prepared = try PipelineSystemFont.prepare(design: key.design,
          weight: key.weight, strings: key.strings)
        preparedFonts[key] = prepared
      }
      preparedFontOrder.removeAll { $0 == key }
      preparedFontOrder.append(key)
      if preparedFontOrder.count > 8 {
        preparedFonts.removeValue(forKey: preparedFontOrder.removeFirst())
      }
      fonts[resource.name] = prepared
      fontFingerprints[resource.name] = prepared.fingerprint
    }
    let declaredBytes = definition.resources.reduce(0) { total, resource in
      total + (resource.kind == "buffer" ? resource.bytes ?? 0
        : resource.kind == "texture" ? size.pixels * 8 : 0)
    }
    let inputBytes = inputImages.values.reduce(0) {
      $0 + $1.width * $1.height * 8
    }
    let fontBytes = fonts.values.reduce(0) { $0 + $1.bytes.count }
    guard declaredBytes + inputBytes + fontBytes <= 134_217_728 else {
      throw PipelineEngineError.invalidInvocation("GPU Program resources exceed 128 MiB.")
    }
    let frame = try context.invocation.integer(
      for: PipelineInvocation.loopCallIndexKey, default: 0)
    guard (0...Int(UInt32.max)).contains(frame) else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program frame index must fit its 32-bit frame uniform.")
    }
    let identity = Identity(runID: context.runID, nodeID: node.id,
      semanticSHA256: context.semanticSHA256, program: programJSON,
      source: source, parameterJSON: parameterJSON,
      width: width, height: height, seed: seed, framesPerSecond: fps,
      inputImageHashes: inputImageHashes, fontFingerprints: fontFingerprints)
    let library: any MTLLibrary
    if let cachedLibrary, cachedLibrary.source == source {
      library = cachedLibrary.library
    } else {
      library = try await queue.device.makeLibrary(source: source, options: nil)
      cachedLibrary = (source, library)
      computePipelines = [:]
      renderPipelines = [:]
    }
    let previous = committed[node.id]
    let base = previous?.identity == identity && previous!.nextFrame <= frame
      ? previous : nil
    guard frame - (base?.nextFrame ?? 0) < 3_600 else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program can replay at most 3,600 frames per call.")
    }
    var working: Session
    if let base {
      let cloneStartedAt = DispatchTime.now().uptimeNanoseconds
      working = Session(identity: identity,
        resources: try await clone(base.resources,
          excluding: directPreview ? definition.output : nil), nextFrame: base.nextFrame)
      currentPerformance?.cloneSeconds = Self.seconds(since: cloneStartedAt)
    } else {
      working = Session(identity: identity,
        resources: try makeResources(definition, size: size, inputImages: inputImages,
          fonts: fonts,
          excluding: directPreview ? definition.output : nil),
        nextFrame: 0)
      try await clearTextures(working.resources)
    }
    // Live controls may have moved while upstream assets were evaluated. Read
    // them immediately before advancing the GPU state for this frame.
    var framePointer = previewOnly && liveRunID == context.runID
      ? livePointer?.value ?? pointer : pointer
    var frameMovement = movement
    if previewOnly && liveRunID == context.runID,
      let livePointer {
      frameMovement.z = livePointer.secondaryActionCount
    }
    let liveTickNanoseconds: UInt64? = previewOnly
      ? DispatchTime.now().uptimeNanoseconds : nil
    if let liveTickNanoseconds {
      let elapsed = lastLiveTickNanoseconds.flatMap { previous in
        liveTickNanoseconds >= previous
          ? Double(liveTickNanoseconds - previous) / 1_000_000_000 : nil
      } ?? 1 / fps
      framePointer.w = Float(min(elapsed, 0.1))
    }
    if base == nil {
      try await encode(definition.initialize, library: library,
        resources: working.resources, uniforms: Self.uniforms(size: size,
          frame: 0, fps: fps, seed: seed,
          names: definition.parameters ?? [], values: dictionary, pointer: framePointer,
          movement: frameMovement))
    }
    let directFrame: PipelineMetalPreviewFrame?
    if directPreview {
      guard let runID = context.runID else {
        throw PipelineEngineError.invalidInvocation("GPU Program preview needs a run ID.")
      }
      let (frame, target) = try makePreviewTarget(size: size, runID: runID)
      working.resources[definition.output] = .texture(target)
      directFrame = frame
    } else {
      directFrame = nil
    }
    for index in working.nextFrame...frame {
      try Task.checkCancellation()
      if let name = definition.sceneRequestBuffer,
        case .buffer(let buffer)? = working.resources[name] {
        buffer.contents().storeBytes(of: UInt32.max, as: UInt32.self)
      }
      for event in definition.audioEvents ?? [] {
        if case .buffer(let buffer)? = working.resources[event.buffer] {
          buffer.contents().storeBytes(of: UInt32.zero, as: UInt32.self)
        }
      }
      let includesPresent = definition.swaps.isEmpty && index == frame
      try await encode(includesPresent ? definition.tick + definition.present : definition.tick,
        library: library,
        resources: working.resources, uniforms: Self.uniforms(size: size,
          frame: index, fps: fps, seed: seed,
          names: definition.parameters ?? [], values: dictionary, pointer: framePointer,
          movement: frameMovement))
      for pair in definition.swaps {
        let first = working.resources[pair[0]]
        working.resources[pair[0]] = working.resources[pair[1]]
        working.resources[pair[1]] = first
      }
    }
    working.nextFrame = frame + 1
    if !definition.swaps.isEmpty {
      try await encode(definition.present, library: library,
        resources: working.resources, uniforms: Self.uniforms(size: size,
          frame: frame, fps: fps, seed: seed,
          names: definition.parameters ?? [], values: dictionary, pointer: framePointer,
          movement: frameMovement))
    }
    let sceneRequest: Int64
    if let name = definition.sceneRequestBuffer,
      case .buffer(let buffer)? = working.resources[name] {
      let raw = buffer.contents().load(as: UInt32.self)
      sceneRequest = raw == UInt32.max ? -1 : Int64(raw)
    } else {
      sceneRequest = -1
    }
    var audioEventURLs: [URL] = []
    for event in definition.audioEvents ?? [] {
      guard case .buffer(let buffer)? = working.resources[event.buffer],
        let url = audioAssets[event.asset] else { continue }
      let count = buffer.contents().load(as: UInt32.self)
      guard count <= 8 else {
        throw PipelineEngineError.invalidInvocation(
          "GPU Program audio event count must be at most 8 per frame.")
      }
      audioEventURLs.append(contentsOf: repeatElement(url, count: Int(count)))
    }
    guard case .texture(let output)? = working.resources[definition.output] else {
      throw PipelineEngineError.invalidInvocation("GPU Program output is not a texture.")
    }
    let image: PipelineImageInput?
    if previewOnly {
      guard let runID = context.runID else {
        throw PipelineEngineError.invalidInvocation("GPU Program preview needs a run ID.")
      }
      if let directFrame {
        liveFrame = directFrame
      } else {
        let copyStartedAt = DispatchTime.now().uptimeNanoseconds
        liveFrame = try await copyPreview(output, size: size, runID: runID)
        currentPerformance?.previewCopySeconds = Self.seconds(since: copyStartedAt)
      }
      image = nil
    } else {
      let readbackStartedAt = DispatchTime.now().uptimeNanoseconds
      image = try Self.readImage(output, size: size)
      currentPerformance?.readbackSeconds = Self.seconds(since: readbackStartedAt)
    }
    try Task.checkCancellation()
    pending[node.id] = working
    pendingAudioEvents[node.id] = (context.runID, audioEventURLs)
    pendingLiveTickNanoseconds = liveTickNanoseconds
    if var sample = currentPerformance, let runID = context.runID {
      sample.renderSeconds = Self.seconds(since: renderStartedAt)
      completedPerformance.withLock { $0 = (runID, sample) }
    }
    currentPerformance = nil
    return Frame(image: image, sceneRequest: sceneRequest)
  }

  private func copyPreview(_ texture: any MTLTexture,
    size: PipelineMetalRenderSize, runID: UUID) async throws -> PipelineMetalPreviewFrame {
    let (frame, target) = try makePreviewTarget(size: size, runID: runID)
    guard let command = queue.makeCommandBuffer(),
      let blit = command.makeBlitCommandEncoder() else {
      throw PipelineEngineError.invalidInvocation("GPU Program preview copy failed.")
    }
    blit.copy(from: texture, to: target)
    blit.endEncoding()
    try await finish(command)
    return frame
  }

  private func makePreviewTarget(size: PipelineMetalRenderSize,
    runID: UUID) throws -> (PipelineMetalPreviewFrame, any MTLTexture) {
    if surfaceSize?.width != size.width || surfaceSize?.height != size.height {
      allocatedSurfaceCount -= reusableSurfaces.count
      reusableSurfaces = []
      surfaceSize = (size.width, size.height)
    }
    let surface: IOSurface
    if let recycled = reusableSurfaces.popLast() {
      surface = recycled
    } else {
      guard allocatedSurfaceCount < 4,
        let created = IOSurface(properties: [
          .width: size.width, .height: size.height,
          .bytesPerElement: 8, .pixelFormat: kCVPixelFormatType_64RGBAHalf,
          .name: "Pixeltje GPU Program preview",
        ]) else {
        throw PipelineEngineError.invalidInvocation("GPU Program preview surface allocation failed.")
      }
      surface = created
      allocatedSurfaceCount += 1
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float, width: size.width,
      height: size.height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .renderTarget]
    guard let target = queue.device.makeTexture(descriptor: descriptor,
      iosurface: surface, plane: 0) else {
      recycle(surface)
      throw PipelineEngineError.invalidInvocation("GPU Program preview texture allocation failed.")
    }
    let lease = PipelineMetalPreviewSurfaceLease(surface: surface) { [weak self] returned in
      Task { await self?.recycle(returned) }
    }
    return (PipelineMetalPreviewFrame(surface: surface, width: size.width,
      height: size.height, runID: runID, lease: lease), target)
  }

  /// The output has no history when the first output pass clears it and all
  /// following output passes only add to that same frame.
  private static func canRenderDirectlyToPreview(_ program: Definition) -> Bool {
    func readsOutput(_ pass: Definition.Pass) -> Bool {
      [pass.textures, pass.vertexTextures, pass.fragmentTextures].contains { mapping in
        mapping?.values.contains(program.output) == true
      }
    }
    let outputPasses = program.present.filter { $0.target == program.output }
    guard let first = outputPasses.first, first.kind == "render",
      first.load != "load", first.blend == nil || first.blend == "replace",
      outputPasses.dropFirst().allSatisfy({ $0.kind == "render" && $0.load == "load" }),
      program.present.allSatisfy({ !readsOutput($0) }),
      (program.initialize + program.tick).allSatisfy({
        $0.target != program.output && !readsOutput($0)
      }) else { return false }
    return true
  }

  private func recycle(_ surface: IOSurface) {
    guard surfaceSize?.width == IOSurfaceGetWidth(surface),
      surfaceSize?.height == IOSurfaceGetHeight(surface) else {
      allocatedSurfaceCount -= 1
      return
    }
    reusableSurfaces.append(surface)
  }

  private static func dimension(_ name: String, node: PipelineNode,
    inputs: [String: PipelineNodeValue]) throws -> Int {
    let value = inputs[name]?.value(as: Int64.self)
      ?? inputs[name]?.value(as: Int.self).map(Int64.init)
      ?? node.parameters[name]?.integerValue ?? 512
    guard (1...4096).contains(value), let result = Int(exactly: value) else {
      throw PipelineEngineError.invalidInvocation("GPU Program \(name) must be 1–4096.")
    }
    return result
  }

  private static func pointerCoordinate(_ name: String,
    inputs: [String: PipelineNodeValue]) throws -> Double {
    let value = inputs[name]?.value(as: Double.self) ?? 0.5
    guard value.isFinite, (0...1).contains(value) else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program \(name) must be a normalized number from 0 to 1.")
    }
    return value
  }

  private static func movementCoordinate(_ name: String,
    inputs: [String: PipelineNodeValue]) throws -> Double {
    let value = inputs[name]?.value(as: Double.self) ?? 0
    guard value.isFinite, (-1...1).contains(value) else {
      throw PipelineEngineError.invalidInvocation(
        "GPU Program \(name) must be a number from -1 to 1.")
    }
    return value
  }

  private static func identifier(_ value: String) -> Bool {
    guard let first = value.utf8.first,
      (65...90).contains(first) || (97...122).contains(first) || first == 95,
      value.utf8.count <= 64 else { return false }
    return value.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0)
        || (48...57).contains($0) || $0 == 95
    }
  }

  private static func validate(_ program: Definition, size: PipelineMetalRenderSize,
    parameters: [String: NSNumber]) throws {
    func fail(_ message: String) -> PipelineEngineError {
      .invalidInvocation("GPU Program: \(message)")
    }
    guard (1...2).contains(program.version), (1...12).contains(program.resources.count),
      program.initialize.count <= 16, (1...16).contains(program.tick.count),
      (1...16).contains(program.present.count), program.swaps.count <= 8,
      (program.parameters?.count ?? 0) <= 16 else {
      throw fail("unsupported version or pass/resource count.")
    }
    var names = Set<String>()
    var kinds: [String: String] = [:]
    var memory = 0
    for resource in program.resources {
      guard identifier(resource.name), names.insert(resource.name).inserted else {
        throw fail("resource names must be unique Metal identifiers.")
      }
      kinds[resource.name] = resource.kind
      switch resource.kind {
      case "buffer":
        guard resource.input == nil, resource.design == nil,
          resource.weight == nil, resource.strings == nil, let bytes = resource.bytes,
          (1...16_777_216).contains(bytes) else {
          throw fail("buffer size must be 1–16 MiB.")
        }
        memory += bytes
      case "texture":
        guard resource.bytes == nil, resource.input == nil,
          resource.design == nil, resource.weight == nil,
          resource.strings == nil else {
          throw fail("textures use output dimensions.")
        }
        memory += size.pixels * 8
      case "inputTexture":
        guard resource.bytes == nil, resource.design == nil,
          resource.weight == nil, resource.strings == nil,
          let input = resource.input,
          identifier(input),
          !program.resources.contains(where: {
            $0.name != resource.name && $0.kind == "inputTexture" && $0.input == input
          }) else { throw fail("input textures need distinct asset names.") }
        // Input dimensions are checked against the total budget at execution.
      case "systemFont":
        guard program.version == 2, resource.bytes == nil, resource.input == nil,
          ["system", "monospaced", "monospacedDigits"].contains(resource.design ?? ""),
          ["regular", "medium", "semibold", "bold"].contains(resource.weight ?? ""),
          let strings = resource.strings, (1...64).contains(strings.count),
          strings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 80 }),
          strings.reduce(0, { $0 + $1.utf8.count }) <= 4_096 else {
          throw fail("systemFont needs a design, weight, and bounded strings in version 2.")
        }
      default: throw fail("unsupported resource kind.")
      }
    }
    guard memory <= 134_217_728, kinds[program.output] == "texture" else {
      throw fail("resources exceed 128 MiB or output is not a texture.")
    }
    if let name = program.sceneRequestBuffer {
      guard let resource = program.resources.first(where: { $0.name == name }),
        resource.kind == "buffer", resource.bytes == 4 else {
        throw fail("sceneRequestBuffer must name a dedicated 4-byte buffer.")
      }
    }
    let audioEvents = program.audioEvents ?? []
    guard audioEvents.count <= 8,
      Set(audioEvents.map(\.buffer)).count == audioEvents.count,
      audioEvents.allSatisfy({ event in
        identifier(event.asset) && kinds[event.buffer] == "buffer"
          && program.resources.first(where: { $0.name == event.buffer })?.bytes == 4
          && event.buffer != program.sceneRequestBuffer
      }) else {
      throw fail("audio events need distinct dedicated 4-byte buffers and asset names.")
    }
    guard program.present.contains(where: {
      $0.kind == "render" && $0.target == program.output
    }) else {
      throw fail("a present render pass must write the output texture.")
    }
    let parameterNames = program.parameters ?? []
    guard Set(parameterNames).count == parameterNames.count,
      parameterNames.allSatisfy(identifier),
      parameters.keys.allSatisfy(parameterNames.contains),
      parameters.values.allSatisfy({ $0.doubleValue.isFinite
        && abs($0.doubleValue) <= 1_000_000 }) else {
      throw fail("parameter names or values are invalid.")
    }
    for pair in program.swaps {
      guard pair.count == 2, pair[0] != pair[1],
        kinds[pair[0]] == kinds[pair[1]],
        ["buffer", "texture"].contains(kinds[pair[0]] ?? ""),
        program.output != pair[0], program.output != pair[1] else {
        throw fail("swap pairs need matching, distinct non-output resources.")
      }
    }
    for pass in program.initialize + program.tick + program.present {
      func bindings(_ mapping: [String: String]?, kind: String) throws {
        for (slot, name) in mapping ?? [:] {
          guard let index = Int(slot), (1...15).contains(index),
            (kinds[name] == kind || kind == "buffer" && kinds[name] == "systemFont"
              || kind == "texture" && kinds[name] == "inputTexture") else {
            throw fail("binding slots must be 1–15 and match resource types.")
          }
        }
      }
      try bindings(pass.buffers, kind: "buffer")
      try bindings(pass.vertexBuffers, kind: "buffer")
      try bindings(pass.fragmentBuffers, kind: "buffer")
      try bindings(pass.textures, kind: "texture")
      try bindings(pass.vertexTextures, kind: "texture")
      try bindings(pass.fragmentTextures, kind: "texture")
      switch pass.kind {
      case "compute":
        guard pass.vertex == nil, pass.fragment == nil, pass.target == nil,
          pass.vertexCount == nil, pass.instanceCount == nil,
          pass.load == nil, pass.blend == nil,
          (pass.vertexBuffers ?? [:]).isEmpty,
          (pass.fragmentBuffers ?? [:]).isEmpty,
          (pass.vertexTextures ?? [:]).isEmpty,
          (pass.fragmentTextures ?? [:]).isEmpty else {
          throw fail("compute passes cannot contain render settings.")
        }
        guard let function = pass.function, identifier(function),
          let threads = pass.threads, (1...3).contains(threads.count),
          threads.allSatisfy({ (1...4096).contains($0) }),
          threads.reduce(1, { $0 * $1 }) <= 16_777_216 else {
          throw fail("compute pass needs a function and bounded threads.")
        }
      case "render":
        guard pass.function == nil, pass.threads == nil,
          (pass.buffers ?? [:]).isEmpty,
          (pass.textures ?? [:]).isEmpty else {
          throw fail("render passes cannot contain compute settings.")
        }
        guard let vertex = pass.vertex, let fragment = pass.fragment,
          identifier(vertex), identifier(fragment),
          let target = pass.target, kinds[target] == "texture",
          let count = pass.vertexCount, (1...1_048_576).contains(count),
          (1...65_536).contains(pass.instanceCount ?? 1),
          [nil, "clear", "load"].contains(pass.load),
          [nil, "replace", "additive", "alpha"].contains(pass.blend) else {
          throw fail("render pass has invalid functions, target, or draw settings.")
        }
      default: throw fail("pass kind must be compute or render.")
      }
    }
  }

  private func makeResources(_ program: Definition,
    size: PipelineMetalRenderSize,
    inputImages: [String: PipelineImageInput],
    fonts: [String: PipelineSystemFont.Prepared],
    excluding excluded: String? = nil) throws -> [String: Resource] {
    var result: [String: Resource] = [:]
    for item in program.resources {
      if item.name == excluded { continue }
      if item.kind == "buffer" {
        guard let buffer = queue.device.makeBuffer(length: item.bytes!, options: .storageModeShared)
        else { throw PipelineEngineError.invalidInvocation("GPU Program buffer allocation failed.") }
        memset(buffer.contents(), 0, buffer.length)
        result[item.name] = .buffer(buffer)
      } else if item.kind == "systemFont" {
        guard let prepared = fonts[item.name] else {
          throw PipelineEngineError.invalidInvocation("GPU Program system font is missing.")
        }
        let buffer: any MTLBuffer
        if let cached = fontBuffers[prepared.fingerprint] { buffer = cached }
        else {
          guard let created = queue.device.makeBuffer(length: prepared.bytes.count,
            options: .storageModeShared) else {
            throw PipelineEngineError.invalidInvocation("GPU Program font allocation failed.")
          }
          _ = prepared.bytes.withUnsafeBytes { bytes in
            memcpy(created.contents(), bytes.baseAddress!, bytes.count)
          }
          fontBuffers[prepared.fingerprint] = created
          buffer = created
        }
        fontBufferOrder.removeAll { $0 == prepared.fingerprint }
        fontBufferOrder.append(prepared.fingerprint)
        if fontBufferOrder.count > 8 {
          fontBuffers.removeValue(forKey: fontBufferOrder.removeFirst())
        }
        result[item.name] = .immutableBuffer(buffer)
      } else if item.kind == "inputTexture" {
        guard let port = item.input, let image = inputImages[port] else {
          throw PipelineEngineError.invalidInvocation("GPU Program input texture is missing.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba16Float, width: image.width,
          height: image.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = queue.device.makeTexture(descriptor: descriptor) else {
          throw PipelineEngineError.invalidInvocation("GPU Program input texture allocation failed.")
        }
        let half = image.rgba.map(Float16.init)
        half.withUnsafeBytes { bytes in
          texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
            mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: image.width * 8)
        }
        result[item.name] = .inputTexture(texture)
      } else {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba16Float, width: size.width,
          height: size.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = queue.device.makeTexture(descriptor: descriptor) else {
          throw PipelineEngineError.invalidInvocation("GPU Program texture allocation failed.")
        }
        result[item.name] = .texture(texture)
      }
    }
    return result
  }

  private func clone(_ resources: [String: Resource],
    excluding excluded: String? = nil) async throws -> [String: Resource] {
    var copies: [String: Resource] = [:]
    var command: (any MTLCommandBuffer)?
    var blit: (any MTLBlitCommandEncoder)?
    func encoder() throws -> any MTLBlitCommandEncoder {
      if let blit { return blit }
      guard let created = queue.makeCommandBuffer(),
        let createdEncoder = created.makeBlitCommandEncoder() else {
        throw PipelineEngineError.invalidInvocation("GPU Program cannot copy frame state.")
      }
      command = created
      blit = createdEncoder
      return createdEncoder
    }
    for (name, resource) in resources {
      if name == excluded { continue }
      switch resource {
      case .buffer(let source):
        guard let copy = queue.device.makeBuffer(length: source.length,
          options: .storageModeShared) else {
          throw PipelineEngineError.invalidInvocation("GPU Program buffer allocation failed.")
        }
        if source.length <= 65_536 {
          memcpy(copy.contents(), source.contents(), source.length)
        } else {
          try encoder().copy(from: source, sourceOffset: 0, to: copy,
            destinationOffset: 0, size: source.length)
        }
        copies[name] = .buffer(copy)
      case .immutableBuffer(let source):
        copies[name] = .immutableBuffer(source)
      case .texture(let source):
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba16Float, width: source.width,
          height: source.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let copy = queue.device.makeTexture(descriptor: descriptor) else {
          throw PipelineEngineError.invalidInvocation("GPU Program texture allocation failed.")
        }
        try encoder().copy(from: source, to: copy)
        copies[name] = .texture(copy)
      case .inputTexture(let source):
        copies[name] = .inputTexture(source)
      }
    }
    if let blit, let command {
      blit.endEncoding()
      try await finish(command)
    }
    return copies
  }

  private func clearTextures(_ resources: [String: Resource]) async throws {
    guard let command = queue.makeCommandBuffer() else {
      throw PipelineEngineError.invalidInvocation("GPU Program texture initialization failed.")
    }
    for resource in resources.values {
      guard case .texture(let texture) = resource else { continue }
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
        throw PipelineEngineError.invalidInvocation("GPU Program texture initialization failed.")
      }
      encoder.endEncoding()
    }
    try await finish(command)
  }

  private static func uniforms(size: PipelineMetalRenderSize, frame: Int,
    fps: Double, seed: UInt64, names: [String], values: [String: NSNumber],
    pointer: SIMD4<Float>, movement: SIMD4<Float>) -> Uniforms {
    var numbers = [Float](repeating: 0, count: 16)
    for (index, name) in names.enumerated() { numbers[index] = values[name]?.floatValue ?? 0 }
    return Uniforms(
      resolutionTime: SIMD4(Float(size.width), Float(size.height),
        Float(Double(frame) / fps), Float(1 / fps)),
      frameSeed: SIMD4(UInt32(frame), UInt32(truncatingIfNeeded: seed),
        UInt32(truncatingIfNeeded: seed >> 32), 0),
      parameters0: SIMD4(numbers[0], numbers[1], numbers[2], numbers[3]),
      parameters1: SIMD4(numbers[4], numbers[5], numbers[6], numbers[7]),
      parameters2: SIMD4(numbers[8], numbers[9], numbers[10], numbers[11]),
      parameters3: SIMD4(numbers[12], numbers[13], numbers[14], numbers[15]),
      pointer: pointer,
      movement: movement)
  }

  private func encode(_ passes: [Definition.Pass], library: any MTLLibrary,
    resources: [String: Resource], uniforms: Uniforms) async throws {
    guard let command = queue.makeCommandBuffer() else {
      throw PipelineEngineError.invalidInvocation("GPU Program command allocation failed.")
    }
    var uniforms = uniforms
    for pass in passes {
      try Task.checkCancellation()
      if pass.kind == "compute" {
        guard let function = library.makeFunction(name: pass.function!),
          let encoder = command.makeComputeCommandEncoder() else {
          throw PipelineEngineError.invalidInvocation("GPU Program compute function is missing.")
        }
        let pipeline: any MTLComputePipelineState
        if let cached = computePipelines[pass.function!] { pipeline = cached }
        else {
          pipeline = try await queue.device.makeComputePipelineState(function: function)
          computePipelines[pass.function!] = pipeline
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        bindBuffers(pass.buffers, resources: resources) {
          encoder.setBuffer($0, offset: 0, index: $1)
        }
        bindTextures(pass.textures, resources: resources) {
          encoder.setTexture($0, index: $1)
        }
        let threads = pass.threads!
        encoder.dispatchThreads(MTLSize(width: threads[0],
          height: threads.count > 1 ? threads[1] : 1,
          depth: threads.count > 2 ? threads[2] : 1),
          threadsPerThreadgroup: MTLSize(width: min(pipeline.threadExecutionWidth, threads[0]),
            height: 1, depth: 1))
        encoder.endEncoding()
      } else {
        guard case .texture(let target)? = resources[pass.target!],
          let vertex = library.makeFunction(name: pass.vertex!),
          let fragment = library.makeFunction(name: pass.fragment!) else {
          throw PipelineEngineError.invalidInvocation("GPU Program render function or target is missing.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let attachment = descriptor.colorAttachments[0]!
        switch pass.blend ?? "replace" {
        case "additive":
          attachment.isBlendingEnabled = true
          attachment.sourceRGBBlendFactor = .one
          attachment.destinationRGBBlendFactor = .one
          attachment.sourceAlphaBlendFactor = .one
          attachment.destinationAlphaBlendFactor = .one
        case "alpha":
          attachment.isBlendingEnabled = true
          attachment.sourceRGBBlendFactor = .sourceAlpha
          attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
          attachment.sourceAlphaBlendFactor = .one
          attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        default: break
        }
        let key = "\(pass.vertex!)|\(pass.fragment!)|\(pass.blend ?? "replace")"
        let pipeline: any MTLRenderPipelineState
        if let cached = renderPipelines[key] { pipeline = cached }
        else {
          pipeline = try await queue.device.makeRenderPipelineState(descriptor: descriptor)
          renderPipelines[key] = pipeline
        }
        let render = MTLRenderPassDescriptor()
        render.colorAttachments[0].texture = target
        render.colorAttachments[0].loadAction = pass.load == "load" ? .load : .clear
        render.colorAttachments[0].storeAction = .store
        render.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: render) else {
          throw PipelineEngineError.invalidInvocation("GPU Program render encoding failed.")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        bindBuffers(pass.vertexBuffers, resources: resources) {
          encoder.setVertexBuffer($0, offset: 0, index: $1)
        }
        bindBuffers(pass.fragmentBuffers, resources: resources) {
          encoder.setFragmentBuffer($0, offset: 0, index: $1)
        }
        bindTextures(pass.vertexTextures, resources: resources) {
          encoder.setVertexTexture($0, index: $1)
        }
        bindTextures(pass.fragmentTextures, resources: resources) {
          encoder.setFragmentTexture($0, index: $1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
          vertexCount: pass.vertexCount!, instanceCount: pass.instanceCount ?? 1)
        encoder.endEncoding()
      }
    }
    try await finish(command)
  }

  private func bindBuffers(_ mapping: [String: String]?,
    resources: [String: Resource], set: (any MTLBuffer, Int) -> Void) {
    for (slot, name) in mapping ?? [:] {
      if let index = Int(slot) {
        switch resources[name] {
        case .buffer(let buffer)?, .immutableBuffer(let buffer)?: set(buffer, index)
        default: break
        }
      }
    }
  }

  private func bindTextures(_ mapping: [String: String]?,
    resources: [String: Resource], set: (any MTLTexture, Int) -> Void) {
    for (slot, name) in mapping ?? [:] {
      guard let index = Int(slot) else { continue }
      switch resources[name] {
      case .texture(let texture)?, .inputTexture(let texture)?: set(texture, index)
      default: break
      }
    }
  }

  private func finish(_ command: any MTLCommandBuffer) async throws {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let failure: String? = await withCheckedContinuation { continuation in
      command.addCompletedHandler { result in
        continuation.resume(returning: result.status == .completed ? nil
          : result.error?.localizedDescription ?? "GPU Program command failed.")
      }
      command.commit()
    }
    if currentPerformance != nil {
      currentPerformance?.gpuCommandCount += 1
      currentPerformance?.commandWaitSeconds += Self.seconds(since: startedAt)
      if command.gpuStartTime > 0, command.gpuEndTime >= command.gpuStartTime {
        currentPerformance?.gpuTimedCommandCount += 1
        currentPerformance?.gpuExecutionSeconds += command.gpuEndTime - command.gpuStartTime
      }
    }
    if let failure { throw PipelineEngineError.invalidInvocation(failure) }
    try Task.checkCancellation()
  }

  private static func seconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
  }

  private static func readImage(_ texture: any MTLTexture,
    size: PipelineMetalRenderSize) throws -> PipelineImageInput {
    var half = [Float16](repeating: 0, count: size.pixels * 4)
    half.withUnsafeMutableBytes { bytes in
      texture.getBytes(bytes.baseAddress!, bytesPerRow: size.width * 8,
        from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0)
    }
    var rgba = [Float](repeating: 0, count: half.count)
    for index in 0..<size.pixels {
      if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
      let alpha = Float(half[index * 4 + 3])
      let coverage = alpha.isFinite ? min(1, max(0, alpha)) : 0
      rgba[index * 4 + 3] = coverage
      for channel in 0..<3 {
        let component = Float(half[index * 4 + channel])
        rgba[index * 4 + channel] =
          (component.isFinite ? min(1, max(0, component)) : 0) * coverage
      }
    }
    return try PipelineImageInput(width: size.width, height: size.height, rgba: rgba)
  }
}
