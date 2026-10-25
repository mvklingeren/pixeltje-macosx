import Foundation
import CoreVideo
import IOSurface
import Metal
import PixeltjePipelineDomain
import simd
import Synchronization

/// Guards array and row-stride arithmetic without imposing a product resolution cap.
struct PipelineMetalRenderSize {
  let width: Int
  let height: Int
  let pixels: Int

  init(width: Int, height: Int) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow,
      pixels <= Int.max / 16, width <= Int.max / 8 else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render needs positive dimensions with a representable pixel buffer.")
    }
    self.width = width
    self.height = height
    self.pixels = pixels
  }
}

/// A completed GPU preview. Its surface is recycled when every presenter
/// releases the frame; no CPU pixels cross the engine/editor boundary.
public struct PipelineMetalPreviewFrame: Sendable {
  public let surface: IOSurface
  public let width: Int
  public let height: Int
  public let runID: UUID
  private let lease: PipelineMetalPreviewSurfaceLease

  init(surface: IOSurface, width: Int, height: Int, runID: UUID,
    lease: PipelineMetalPreviewSurfaceLease) {
    self.surface = surface
    self.width = width
    self.height = height
    self.runID = runID
    self.lease = lease
  }
}

final class PipelineMetalPreviewSurfaceLease: @unchecked Sendable {
  let surface: IOSurface
  let recycle: @Sendable (IOSurface) -> Void

  init(surface: IOSurface, recycle: @escaping @Sendable (IOSurface) -> Void) {
    self.surface = surface
    self.recycle = recycle
  }

  deinit { recycle(surface) }
}

/// Model-free rasterizer on the engine's own Metal command queue.
/// GPU resources stay in this actor; completed IOSurfaces cross only the
/// transient preview boundary, while graph image ports remain CPU rasters.
actor PipelineMeshRenderer {
  private struct ShaderKey: Hashable {
    let source: String
    let fragmentFunction: String
  }

  private let commandQueue: any MTLCommandQueue
  private var pipeline: (any MTLRenderPipelineState)?
  private var shaderPipelines: [ShaderKey: any MTLRenderPipelineState] = [:]
  private var shaderCacheOrder: [ShaderKey] = []
  private var depthState: (any MTLDepthStencilState)?
  private var sampleCount = 1
  private struct LivePreview {
    let state: PipelineMetalShaderState
    let source: String
    let dimensions: [String: PipelineNodeValue]
    let invocation: PipelineInvocation
    let previewSize: PipelineMetalRenderSize?
    let semanticSHA256: String
    let capturedAt: UInt64
    let timeStep: Double
    let callInterval: Double
  }
  private var liveRunID: UUID?
  private var liveNodeID: PipelineNodeID?
  private var livePreview: LivePreview?
  private var reusablePreviewSurfaces: [IOSurface] = []
  private var previewSurfaceSize: (width: Int, height: Int)?
  private var allocatedPreviewSurfaceCount = 0
  private let maximumPreviewSurfaces = 4

  init(commandQueue: any MTLCommandQueue) {
    self.commandQueue = commandQueue
  }

  static func executor(renderer: PipelineMeshRenderer) -> PipelineNodeExecutor {
    .init(kind: .renderMetal) { node, inputs, context in
      let result: PipelineNodeResult
      if let stateValue = inputs["state"] {
        guard let json = stateValue.value(as: String.self) else {
          throw PipelineEngineError.invalidInvocation("Metal Render state must be a JSON object.")
        }
        let previewSize = try Self.previewSize(from: context.invocation)
        let previewOnly: Bool
        switch context.invocation[PipelineInvocation.metalPreviewOnlyKey] {
        case .boolean(let enabled): previewOnly = enabled
        case nil: previewOnly = false
        default:
          throw PipelineEngineError.invalidInvocation("Metal preview-only must be Boolean.")
        }
        guard !previewOnly || previewSize != nil else {
          throw PipelineEngineError.invalidInvocation("Metal preview-only needs preview dimensions.")
        }
        let state = try PipelineMetalShaderState(json: json)
        let source = try Self.shaderSource(inputs: inputs, context: context)
        let image = try await renderer.shaderImage(
          state: state, source: source, inputs: inputs, invocation: context.invocation,
          overrideSize: previewOnly ? previewSize : nil)
        result = try Self.shaderResult(image)
        if let previewSize, !previewOnly,
          (previewSize.width != image.width || previewSize.height != image.height) {
          let preview = try await renderer.shaderImage(
            state: state, source: source, inputs: inputs, invocation: context.invocation,
            overrideSize: previewSize)
          try await reportPreview(preview, nodeID: node.id, context: context)
        } else {
          try await reportPreview(image, nodeID: node.id, context: context)
        }
        await renderer.captureLivePreview(
          nodeID: node.id, state: state, source: source, inputs: inputs,
          context: context, previewSize: previewOnly ? previewSize : nil)
      } else {
        result = try await renderer.render(node, inputs: inputs)
        if let image = result.outputs["image"]?.value(as: PipelineImageInput.self) {
          try await reportPreview(image, nodeID: node.id, context: context)
        }
      }
      return result
    }
  }

  func beginLivePreview(runID: UUID, nodeID: PipelineNodeID) {
    liveRunID = runID
    liveNodeID = nodeID
    livePreview = nil
  }

  func endLivePreview(runID: UUID) {
    guard liveRunID == runID else { return }
    liveRunID = nil
    liveNodeID = nil
    livePreview = nil
  }

  func renderLivePreview(runID: UUID) async throws -> PipelineMetalPreviewFrame? {
    guard liveRunID == runID, let snapshot = livePreview else { return nil }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - snapshot.capturedAt)
      / 1_000_000_000
    let fraction = min(1, max(0, elapsed / snapshot.callInterval))
    let frame = try snapshot.invocation.integer(
      for: PipelineInvocation.loopCallIndexKey, default: 0)
    let baseTime = snapshot.state.timeSeconds
      + Double(frame) * snapshot.state.secondsPerFrame
    let time = min(1_000_000, max(0, baseTime + snapshot.timeStep * fraction))
    let size = try shaderSize(state: snapshot.state, inputs: snapshot.dimensions,
      overrideSize: snapshot.previewSize)
    guard let surface = try acquirePreviewSurface(size: size) else { return nil }
    var handedOff = false
    defer { if !handedOff { recyclePreviewSurface(surface) } }
    _ = try await shaderTexture(
      state: snapshot.state, source: snapshot.source, inputs: snapshot.dimensions,
      invocation: snapshot.invocation, overrideSize: snapshot.previewSize,
      overrideTime: time, surface: surface)
    guard liveRunID == runID else { return nil }
    handedOff = true
    let lease = PipelineMetalPreviewSurfaceLease(surface: surface) { [weak self] returned in
      Task { await self?.recyclePreviewSurface(returned) }
    }
    return PipelineMetalPreviewFrame(surface: surface, width: size.width,
      height: size.height, runID: runID, lease: lease)
  }

  func captureShaderPreview(runID: UUID, nodeID: PipelineNodeID,
    inputs: [String: PipelineNodeValue], context: PipelineNodeExecutionContext) throws {
    guard liveRunID == runID, liveNodeID == nodeID else {
      throw PipelineEngineError.invalidInvocation("Metal preview run is no longer active.")
    }
    guard let json = inputs["state"]?.value(as: String.self) else {
      throw PipelineEngineError.invalidInvocation("Metal Render state must be a JSON object.")
    }
    let state = try PipelineMetalShaderState(json: json)
    let source = try Self.shaderSource(inputs: inputs, context: context)
    _ = try prepareShader(source: source, fragmentFunction: state.fragmentFunction)
    let previewOnly = context.invocation[PipelineInvocation.metalPreviewOnlyKey]
      == .boolean(true)
    let size = try Self.previewSize(from: context.invocation)
    captureLivePreview(nodeID: nodeID, state: state, source: source,
      inputs: inputs, context: context, previewSize: previewOnly ? size : nil)
  }

  private func acquirePreviewSurface(size: PipelineMetalRenderSize) throws -> IOSurface? {
    if previewSurfaceSize?.width != size.width
      || previewSurfaceSize?.height != size.height {
      allocatedPreviewSurfaceCount -= reusablePreviewSurfaces.count
      reusablePreviewSurfaces = []
      previewSurfaceSize = (size.width, size.height)
    }
    if let surface = reusablePreviewSurfaces.popLast() { return surface }
    guard allocatedPreviewSurfaceCount < maximumPreviewSurfaces else { return nil }
    guard let surface = IOSurface(properties: [
      .width: size.width, .height: size.height,
      .bytesPerElement: 8, .pixelFormat: kCVPixelFormatType_64RGBAHalf,
      .name: "Pixeltje Pipeline Metal preview",
    ]) else {
      throw PipelineEngineError.invalidInvocation("Metal could not allocate a preview surface.")
    }
    allocatedPreviewSurfaceCount += 1
    return surface
  }

  private func recyclePreviewSurface(_ surface: IOSurface) {
    guard IOSurfaceGetWidth(surface) == previewSurfaceSize?.width,
      IOSurfaceGetHeight(surface) == previewSurfaceSize?.height else {
      allocatedPreviewSurfaceCount -= 1
      return
    }
    reusablePreviewSurfaces.append(surface)
  }

  private func captureLivePreview(
    nodeID: PipelineNodeID, state: PipelineMetalShaderState, source: String,
    inputs: [String: PipelineNodeValue], context: PipelineNodeExecutionContext,
    previewSize: PipelineMetalRenderSize?
  ) {
    guard liveRunID != nil, liveNodeID == nodeID else { return }
    let interval = (try? context.invocation.number(
      for: PipelineInvocation.metalPreviewCallIntervalKey, default: 1.0 / 60))
      ?? 1.0 / 60
    guard interval.isFinite, interval > 0 else { return }
    let step = (try? context.invocation.number(
      for: PipelineInvocation.metalPreviewTimeStepKey,
      default: state.secondsPerFrame)) ?? state.secondsPerFrame
    guard step.isFinite else { return }
    livePreview = LivePreview(
      state: state, source: source,
      dimensions: inputs.filter { $0.key == "width" || $0.key == "height" },
      invocation: context.invocation, previewSize: previewSize,
      semanticSHA256: context.semanticSHA256,
      capturedAt: DispatchTime.now().uptimeNanoseconds,
      timeStep: step, callInterval: interval)
  }

  private static func shaderResult(_ image: PipelineImageInput) throws -> PipelineNodeResult {
    let mask = try PipelineMaskInput(width: image.width, height: image.height,
      coverage: [Float](repeating: 1, count: image.width * image.height))
    return PipelineNodeResult(outputs: [
      "image": PipelineNodeValue(image, type: .image),
      "mask": PipelineNodeValue(mask, type: .mask),
    ])
  }

  private static func shaderSource(
    inputs: [String: PipelineNodeValue],
    context: PipelineNodeExecutionContext
  ) throws -> String {
    try shaderSource(
      supplied: inputs["source"]?.value(as: String.self),
      fileName: inputs["sourceFile"]?.value(as: String.self),
      sourceMediaRoot: context.sourceMediaRoot)
  }

  static let maximumShaderFileBytes = 4_194_304
  static let maximumExpandedShaderBytes = 8_388_608
  static let maximumShaderIncludeDepth = 16
  static let maximumShaderIncludes = 64

  static func shaderSource(
    supplied: String?, fileName: String?, sourceMediaRoot: URL?
  ) throws -> String {
    guard (supplied != nil) != (fileName != nil) else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render needs exactly one shader source: connect Source or Source File.")
    }
    if let supplied {
      guard !supplied.isEmpty, supplied.utf8.count <= maximumExpandedShaderBytes else {
        throw PipelineEngineError.invalidInvocation(
          "Metal Render source must contain 1 to \(maximumExpandedShaderBytes) UTF-8 bytes.")
      }
      return PipelineMetalLibraries.resolving(supplied)
    }
    guard let fileName, !fileName.isEmpty,
      !fileName.contains("/"), !fileName.contains("\\"),
      fileName != ".", fileName != "..", fileName.hasSuffix(".metal"),
      let root = sourceMediaRoot else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render Source File must be a .metal filename beside the workflow.")
    }
    let key = root.standardizedFileURL.path + "\n" + fileName
    if let cached = sourceCache.withLock({ $0[key] }),
      cached.stamps.allSatisfy({ fileStamp($0.path) == $0.stamp }) {
      return cached.source
    }
    var stamps: [(path: String, stamp: FileStamp)] = []
    var activeStack: [String] = []
    var includedOnce: Set<String> = []
    var includeCount = 0
    let expanded = try expandSiblingMetalFile(
      named: fileName, in: root, stamps: &stamps,
      activeStack: &activeStack, includedOnce: &includedOnce,
      includeCount: &includeCount)
    guard expanded.utf8.count <= maximumExpandedShaderBytes else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render source and includes exceed \(maximumExpandedShaderBytes) UTF-8 bytes.")
    }
    let resolved = PipelineMetalLibraries.resolving(expanded)
    sourceCache.withLock { cache in
      if cache.count >= 16 { cache.removeAll() }
      cache[key] = CachedSource(stamps: stamps, source: resolved)
    }
    return resolved
  }

  /// What a source file looked like when it was read. A live loop asks for
  /// its shader every frame; it reads and expands the files again only when
  /// one of them changed.
  private struct FileStamp: Equatable, Sendable {
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let fileNumber: UInt64
  }

  private struct CachedSource: Sendable {
    let stamps: [(path: String, stamp: FileStamp)]
    let source: String
  }

  private static let sourceCache = Mutex<[String: CachedSource]>([:])

  /// The file at path itself, not a symbolic link's target, so a relinked
  /// name reads as changed too.
  private static func fileStamp(_ path: String) -> FileStamp? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return FileStamp(size: Int64(info.st_size),
      modifiedSeconds: info.st_mtimespec.tv_sec,
      modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      fileNumber: UInt64(info.st_ino))
  }

  private static func siblingMetalSource(named fileName: String, in root: URL,
    stamps: inout [(path: String, stamp: FileStamp)]) throws -> (source: String, canonicalPath: String) {
    guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\\"),
      fileName != ".", fileName != "..", fileName.hasSuffix(".metal") else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render includes must name a .metal file beside the workflow.")
    }
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let url = root.appendingPathComponent(fileName).resolvingSymlinksInPath()
      .standardizedFileURL
    guard url.deletingLastPathComponent() == resolvedRoot,
      let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      attributes.isRegularFile == true else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render source file \(fileName) is missing or outside the workflow folder.")
    }
    guard let fileSize = attributes.fileSize, (1...maximumShaderFileBytes).contains(fileSize) else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render source file must contain 1 to \(maximumShaderFileBytes) UTF-8 bytes.")
    }
    // Stamped before reading, so a change during the read shows next time.
    for path in [root.appendingPathComponent(fileName).path, url.path] {
      guard let stamp = fileStamp(path) else {
        throw PipelineEngineError.invalidInvocation(
          "Metal Render source file \(fileName) is missing or outside the workflow folder.")
      }
      if !stamps.contains(where: { $0.path == path && $0.stamp == stamp }) {
        stamps.append((path, stamp))
      }
    }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty, data.count <= maximumShaderFileBytes,
      let source = String(data: data, encoding: .utf8) else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render source file must contain 1 to \(maximumShaderFileBytes) UTF-8 bytes.")
    }
    return (source, url.path)
  }

  private static func expandSiblingMetalFile(
    named fileName: String, in root: URL,
    stamps: inout [(path: String, stamp: FileStamp)],
    activeStack: inout [String],
    includedOnce: inout Set<String>,
    includeCount: inout Int
  ) throws -> String {
    guard activeStack.count <= maximumShaderIncludeDepth else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render local includes exceed the maximum nesting depth of \(maximumShaderIncludeDepth).")
    }
    let (source, canonicalPath) = try siblingMetalSource(
      named: fileName, in: root, stamps: &stamps)
    if includedOnce.contains(canonicalPath) {
      return ""
    }
    if activeStack.contains(canonicalPath) {
      let chain = (activeStack.map { URL(fileURLWithPath: $0).lastPathComponent } + [fileName])
        .joined(separator: " -> ")
      throw PipelineEngineError.invalidInvocation(
        "Metal Render local includes form a cycle: \(chain).")
    }
    let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false)
    if rawLines.contains(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines) == "#pragma once"
    }) {
      includedOnce.insert(canonicalPath)
    }
    activeStack.append(canonicalPath)
    defer { activeStack.removeLast() }

    var lines: [String] = [PipelineMetalLibraries.lineDirective(1, fileName: fileName)]
    for (index, rawLine) in rawLines.enumerated() {
      let lineNumber = index + 1
      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == "#pragma once" {
        lines.append("")
        continue
      }
      guard trimmed.hasPrefix("#include \"") else {
        lines.append(String(rawLine))
        continue
      }
      guard trimmed.hasSuffix("\""), trimmed.count > 11 else {
        throw PipelineEngineError.invalidInvocation(
          "Metal Render has a malformed local include in \(fileName):\(lineNumber).")
      }
      includeCount += 1
      guard includeCount <= maximumShaderIncludes else {
        throw PipelineEngineError.invalidInvocation(
          "Metal Render local includes exceed \(maximumShaderIncludes) expansions.")
      }
      let childName = String(trimmed.dropFirst(10).dropLast())
      let included = try expandSiblingMetalFile(
        named: childName, in: root, stamps: &stamps,
        activeStack: &activeStack, includedOnce: &includedOnce,
        includeCount: &includeCount)
      if !included.isEmpty {
        lines.append(included)
      }
      lines.append(PipelineMetalLibraries.lineDirective(lineNumber + 1, fileName: fileName))
    }
    return lines.joined(separator: "\n")
  }

  private static func previewSize(from invocation: PipelineInvocation) throws
    -> PipelineMetalRenderSize? {
    let width = invocation[PipelineInvocation.metalPreviewWidthKey]
    let height = invocation[PipelineInvocation.metalPreviewHeightKey]
    guard width != nil || height != nil else { return nil }
    guard width != nil, height != nil else {
      throw PipelineEngineError.invalidInvocation("Metal preview needs both dimensions.")
    }
    return try PipelineMetalRenderSize(
      width: invocation.integer(for: PipelineInvocation.metalPreviewWidthKey),
      height: invocation.integer(for: PipelineInvocation.metalPreviewHeightKey))
  }

  private static func reportPreview(
    _ image: PipelineImageInput, nodeID: PipelineNodeID,
    context: PipelineNodeExecutionContext
  ) async throws {
    let preview = try generatedPreview(image,
      semanticSHA256: context.semanticSHA256)
    await context.progress(.init(
      stage: .generating, message: "Metal Render: preview ready",
      completedUnitCount: context.nodeIndex + 1, totalUnitCount: context.nodeCount,
      preview: preview, previewNodeID: nodeID, activeNodeIDs: [nodeID]))
  }

  private static func generatedPreview(
    _ image: PipelineImageInput, semanticSHA256: String
  ) throws -> PipelineGeneratedImage {
    let pixels = image.width * image.height
    var planar = [Float](repeating: 0, count: pixels * 3)
    var alpha = [Float](repeating: 1, count: pixels)
    var isOpaque = true
    for pixel in 0..<pixels {
      if pixel.isMultiple(of: 16_384) { try Task.checkCancellation() }
      let coverage = image.rgba[pixel * 4 + 3]
      alpha[pixel] = coverage
      if coverage != 1 { isOpaque = false }
      if coverage > 0 {
        for channel in 0..<3 {
          planar[channel * pixels + pixel] = image.rgba[pixel * 4 + channel] / coverage
        }
      }
    }
    return PipelineGeneratedImage(width: image.width, height: image.height,
      planarRGB: planar, encoding: .sRGBZeroToOne,
      semanticPipelineSHA256: semanticSHA256,
      alpha: isOpaque ? nil : alpha)
  }

  private struct Vertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
  }

  private struct Uniforms {
    var mvp: simd_float4x4
    var normalMatrix: simd_float4x4
    var color: SIMD4<Float>
    var light: SIMD4<Float>
    var ambient: SIMD4<Float>
  }

  private struct ShaderUniforms {
    var resolutionTime: SIMD4<Float>
    var mouse: SIMD4<Float>
  }

  private func prepareShader(source: String, fragmentFunction: String) throws
    -> any MTLRenderPipelineState {
    let key = ShaderKey(source: source, fragmentFunction: fragmentFunction)
    if let pipeline = shaderPipelines[key] { return pipeline }
    let device = commandQueue.device
    let library = try device.makeLibrary(source: source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    guard let vertex = library.makeFunction(name: "fullscreenVertex"),
      let fragment = library.makeFunction(name: fragmentFunction) else {
      throw PipelineEngineError.invalidInvocation(
        "Metal Render source must define fullscreenVertex and fragment \(fragmentFunction).")
    }
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .rgba16Float
    let compiled = try device.makeRenderPipelineState(descriptor: descriptor)
    if shaderCacheOrder.count == 8 {
      shaderPipelines.removeValue(forKey: shaderCacheOrder.removeFirst())
    }
    shaderCacheOrder.append(key)
    shaderPipelines[key] = compiled
    return compiled
  }

  func validateShader(source: String, fragmentFunction: String) throws {
    _ = try prepareShader(source: source, fragmentFunction: fragmentFunction)
  }

  private func shaderImage(
    state: PipelineMetalShaderState, source: String, inputs: [String: PipelineNodeValue],
    invocation: PipelineInvocation, overrideSize: PipelineMetalRenderSize? = nil,
    overrideTime: Double? = nil
  ) async throws -> PipelineImageInput {
    let (target, size) = try await shaderTexture(
      state: state, source: source, inputs: inputs, invocation: invocation,
      overrideSize: overrideSize, overrideTime: overrideTime)
    let width = size.width
    let height = size.height
    let pixels = size.pixels
    var halfRGBA = [Float16](repeating: 0, count: pixels * 4)
    halfRGBA.withUnsafeMutableBytes {
      target.getBytes($0.baseAddress!, bytesPerRow: width * 8,
        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    // The source shader applies display gamma itself, so these values already
    // satisfy the pipeline's premultiplied display-referred sRGB image contract.
    var rgba = [Float](repeating: 0, count: pixels * 4)
    for pixel in 0..<pixels {
      if pixel.isMultiple(of: 16_384) { try Task.checkCancellation() }
      let rawAlpha = Float(halfRGBA[pixel * 4 + 3])
      let alpha = rawAlpha.isFinite ? min(1, max(0, rawAlpha)) : 0
      rgba[pixel * 4 + 3] = alpha
      for channel in 0..<3 {
        let value = Float(halfRGBA[pixel * 4 + channel])
        rgba[pixel * 4 + channel] = (value.isFinite ? min(1, max(0, value)) : 0) * alpha
      }
    }
    return try PipelineImageInput(width: width, height: height, rgba: rgba)
  }

  private func shaderSize(state: PipelineMetalShaderState,
    inputs: [String: PipelineNodeValue], overrideSize: PipelineMetalRenderSize?) throws
    -> PipelineMetalRenderSize {
    func dimension(_ name: String, fallback: Int) throws -> Int {
      guard let input = inputs[name] else { return fallback }
      let value = input.value(as: Int64.self) ?? input.value(as: Int.self).map(Int64.init)
      guard let value, value > 0, let exact = Int(exactly: value) else {
        throw PipelineEngineError.invalidInvocation(
          "Metal shader \(name) input must be a positive integer.")
      }
      return exact
    }
    return try PipelineMetalRenderSize(
      width: overrideSize?.width ?? dimension("width", fallback: state.width),
      height: overrideSize?.height ?? dimension("height", fallback: state.height))
  }

  private func shaderTexture(
    state: PipelineMetalShaderState, source: String, inputs: [String: PipelineNodeValue],
    invocation: PipelineInvocation, overrideSize: PipelineMetalRenderSize? = nil,
    overrideTime: Double? = nil, surface: IOSurface? = nil
  ) async throws -> (any MTLTexture, PipelineMetalRenderSize) {
    try Task.checkCancellation()
    let size = try shaderSize(state: state, inputs: inputs, overrideSize: overrideSize)
    let width = size.width
    let height = size.height
    let frame = try invocation.integer(
      for: PipelineInvocation.loopCallIndexKey, default: 0)
    guard frame >= 0 else {
      throw PipelineEngineError.invalidInvocation("Metal shader frame index must be non-negative.")
    }
    let time = overrideTime ?? state.timeSeconds + Double(frame) * state.secondsPerFrame
    guard time.isFinite, (0...1_000_000).contains(time) else {
      throw PipelineEngineError.invalidInvocation("Metal shader time exceeds its supported range.")
    }
    let pipeline = try prepareShader(
      source: source, fragmentFunction: state.fragmentFunction)
    let device = commandQueue.device
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float, width: width, height: height,
      mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    let target = surface.map { device.makeTexture(descriptor: descriptor,
      iosurface: $0, plane: 0) } ?? device.makeTexture(descriptor: descriptor)
    guard let target,
      let command = commandQueue.makeCommandBuffer() else {
      throw PipelineEngineError.invalidInvocation("Metal could not allocate a shader render target.")
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw PipelineEngineError.invalidInvocation("Metal could not encode a shader render pass.")
    }
    var uniforms = ShaderUniforms(
      resolutionTime: SIMD4(Float(width), Float(height), Float(time), 0),
      mouse: SIMD4(Float(state.pointer.x * Double(width)),
        Float((1 - state.pointer.y) * Double(height)),
        state.pointer.engaged ? 1 : 0,
        state.pointer.engaged
          ? Float(state.timeSeconds
            + state.pointer.engagedAtCall * state.secondsPerFrame) : 0))
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    let failure: String? = await withCheckedContinuation { continuation in
      command.addCompletedHandler { completed in
        continuation.resume(returning: completed.status == .completed ? nil
          : completed.error?.localizedDescription ?? "Metal shader rendering failed.")
      }
      command.commit()
    }
    if let failure { throw PipelineEngineError.invalidInvocation(failure) }
    try Task.checkCancellation()
    return (target, size)
  }

  private func prepare() throws {
    guard pipeline == nil else { return }
    let device = commandQueue.device
    sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "meshVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "meshFragment")
    descriptor.rasterSampleCount = sampleCount
    descriptor.colorAttachments[0].pixelFormat = .rgba16Float
    descriptor.colorAttachments[1].pixelFormat = .r16Float
    descriptor.depthAttachmentPixelFormat = .depth32Float
    let depth = MTLDepthStencilDescriptor()
    depth.depthCompareFunction = .lessEqual
    depth.isDepthWriteEnabled = true
    guard let state = device.makeDepthStencilState(descriptor: depth) else {
      throw PipelineEngineError.invalidInvocation("Metal could not create mesh depth testing.")
    }
    let compiled = try device.makeRenderPipelineState(descriptor: descriptor)
    depthState = state
    pipeline = compiled
  }

  private func render(_ node: PipelineNode, inputs: [String: PipelineNodeValue]) async throws
    -> PipelineNodeResult {
    try Task.checkCancellation()
    guard let mesh = inputs["mesh"]?.value(as: PipelineMesh3D.self),
      let view = inputs["viewMatrix"]?.value(as: PipelineMatrix4x4.self),
      let projection = inputs["projectionMatrix"]?.value(as: PipelineMatrix4x4.self) else {
      throw PipelineEngineError.invalidInvocation("Metal Render mesh mode needs a mesh, viewMatrix and projectionMatrix.")
    }
    let world: simd_float4x4
    if let input = inputs["worldMatrix"] {
      guard let matrix = input.value(as: PipelineMatrix4x4.self) else {
        throw PipelineEngineError.invalidInvocation("worldMatrix needs a matrix4x4.")
      }
      world = matrix.value
    } else { world = matrix_identity_float4x4 }
    guard world.columns.0.w == 0, world.columns.1.w == 0,
      world.columns.2.w == 0, world.columns.3.w == 1 else {
      throw PipelineEngineError.invalidInvocation("worldMatrix must be an affine transform.")
    }
    let linear = simd_float3x3(columns: (
      SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
      SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
      SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)))
    let determinant = simd_determinant(linear)
    guard determinant.isFinite, determinant != 0 else {
      throw PipelineEngineError.invalidInvocation("worldMatrix must be invertible for lighting normals.")
    }
    let normals = simd_transpose(simd_inverse(linear))
    let normalMatrix = try PipelineMatrix4x4(simd_float4x4(columns: (
      SIMD4(normals.columns.0, 0), SIMD4(normals.columns.1, 0),
      SIMD4(normals.columns.2, 0), SIMD4(0, 0, 0, 1))))
    let mvp = try PipelineMatrix4x4(projection.value * view.value * world)
    let parameters = PipelineGeometryParameters(node: node, inputs: inputs)
    let width = try parameters.dimension("width")
    let height = try parameters.dimension("height")
    let size = try PipelineMetalRenderSize(width: width, height: height)
    let mode = try parameters.string("mode", default: "filled")
    guard ["filled", "wireframe"].contains(mode) else {
      throw PipelineEngineError.invalidInvocation("Metal Render mesh mode must be filled or wireframe.")
    }
    let color = try Self.color(parameters.string("color", default: "#F28C28"), allowAlpha: false)
    let background = try Self.color(parameters.string("backgroundColor", default: "#00000000"), allowAlpha: true)
    let light = try parameters.vector("light", default: SIMD3(0.5, 0.8, 1))
    let intensity = try parameters.number("lightIntensity", default: 0.8)
    let ambient = try parameters.number("ambient", default: 0.2)
    guard simd_length_squared(light).isFinite, simd_length_squared(light) > 1e-12,
      (0...10).contains(intensity), (0...1).contains(ambient) else {
      throw PipelineEngineError.invalidInvocation("Lighting needs a nonzero direction, intensity 0–10 and ambient 0–1.")
    }
    var uniforms = Uniforms(mvp: mvp.value, normalMatrix: normalMatrix.value,
      color: color, light: SIMD4(simd_normalize(light), intensity),
      ambient: SIMD4(ambient, 0, 0, 0))
    try prepare()
    guard let pipeline, let depthState else {
      throw PipelineEngineError.invalidInvocation("Metal mesh pipeline is unavailable.")
    }
    let device = commandQueue.device
    let vertices = mesh.positions.indices.map {
      Vertex(position: SIMD4(mesh.positions[$0], 1), normal: SIMD4(mesh.normals[$0], 0))
    }
    guard let vertexBuffer = vertices.withUnsafeBytes({ bytes in
      device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
    }), let indexBuffer = mesh.indices.withUnsafeBytes({ bytes in
      device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
    }), let command = commandQueue.makeCommandBuffer() else {
      throw PipelineEngineError.invalidInvocation("Metal could not allocate mesh buffers.")
    }
    func texture(_ format: MTLPixelFormat, samples: Int, shared: Bool = false) throws -> any MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: format, width: width, height: height, mipmapped: false)
      descriptor.sampleCount = samples
      descriptor.textureType = samples == 1 ? .type2D : .type2DMultisample
      descriptor.storageMode = shared ? .shared : .private
      descriptor.usage = .renderTarget
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw PipelineEngineError.invalidInvocation("Metal could not allocate a mesh render target.")
      }
      return texture
    }
    let rgba = try texture(.rgba16Float, samples: 1, shared: true)
    let coverage = try texture(.r16Float, samples: 1, shared: true)
    let renderColor = sampleCount == 1 ? rgba : try texture(.rgba16Float, samples: sampleCount)
    let renderCoverage = sampleCount == 1 ? coverage : try texture(.r16Float, samples: sampleCount)
    let depth = try texture(.depth32Float, samples: sampleCount)
    let pass = MTLRenderPassDescriptor()
    for (index, textures) in [(renderColor, rgba), (renderCoverage, coverage)].enumerated() {
      let attachment = pass.colorAttachments[index]!
      attachment.texture = textures.0
      attachment.loadAction = .clear
      attachment.storeAction = sampleCount == 1 ? .store : .multisampleResolve
      if sampleCount > 1 { attachment.resolveTexture = textures.1 }
    }
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(background.x * background.w), green: Double(background.y * background.w),
      blue: Double(background.z * background.w), alpha: Double(background.w))
    pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    pass.depthAttachment.clearDepth = 1
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw PipelineEngineError.invalidInvocation("Metal could not encode a mesh render pass.")
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setDepthStencilState(depthState)
    encoder.setCullMode(.none)
    encoder.setTriangleFillMode(mode == "wireframe" ? .lines : .fill)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count,
      indexType: .uint32, indexBuffer: indexBuffer, indexBufferOffset: 0)
    encoder.endEncoding()
    let failure: String? = await withCheckedContinuation { continuation in
      command.addCompletedHandler { completed in
        continuation.resume(returning: completed.status == .completed ? nil
          : completed.error?.localizedDescription ?? "Metal mesh rendering failed.")
      }
      command.commit()
    }
    if let failure { throw PipelineEngineError.invalidInvocation(failure) }
    try Task.checkCancellation()
    let pixels = size.pixels
    var halfRGBA = [Float16](repeating: 0, count: pixels * 4)
    var halfCoverage = [Float16](repeating: 0, count: pixels)
    let region = MTLRegionMake2D(0, 0, width, height)
    halfRGBA.withUnsafeMutableBytes {
      rgba.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: region, mipmapLevel: 0)
    }
    halfCoverage.withUnsafeMutableBytes {
      coverage.getBytes($0.baseAddress!, bytesPerRow: width * 2, from: region, mipmapLevel: 0)
    }
    var output = [Float](repeating: 0, count: pixels * 4)
    for pixel in 0..<pixels {
      if pixel.isMultiple(of: 16_384) { try Task.checkCancellation() }
      let alpha = min(1, max(0, Float(halfRGBA[pixel * 4 + 3])))
      output[pixel * 4 + 3] = alpha
      for channel in 0..<3 {
        let linear = alpha > 0 ? Float(halfRGBA[pixel * 4 + channel]) / alpha : 0
        output[pixel * 4 + channel] = Self.encodeSRGB(linear) * alpha
      }
    }
    let image = try PipelineImageInput(width: width, height: height, rgba: output)
    let mask = try PipelineMaskInput(width: width, height: height,
      coverage: halfCoverage.map { min(1, max(0, Float($0))) })
    return PipelineNodeResult(outputs: [
      "image": PipelineNodeValue(image, type: .image),
      "mask": PipelineNodeValue(mask, type: .mask),
    ])
  }

  private static func encodeSRGB(_ value: Float) -> Float {
    let value = min(1, max(0, value))
    return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
  }

  private static func color(_ text: String, allowAlpha: Bool) throws -> SIMD4<Float> {
    let hex = text.hasPrefix("#") ? String(text.dropFirst()) : ""
    guard hex.count == 6 || (allowAlpha && hex.count == 8),
      hex.allSatisfy(\.isHexDigit), let packed = UInt32(hex, radix: 16) else {
      throw PipelineEngineError.invalidInvocation("Colors need #RRGGBB; background also accepts #RRGGBBAA.")
    }
    let value = hex.count == 6 ? (packed << 8) | 255 : packed
    func linear(_ byte: UInt32) -> Float {
      let component = Float(byte & 255) / 255
      return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return SIMD4(linear(value >> 24), linear(value >> 16), linear(value >> 8), Float(value & 255) / 255)
  }

  // Fixed application shader source. A pipeline file cannot supply GPU code.
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position; float4 normal; };
    struct Uniforms {
      float4x4 mvp; float4x4 normalMatrix;
      float4 color; float4 light; float4 ambient;
    };
    struct Varying { float4 position [[position]]; float3 normal; };
    vertex Varying meshVertex(uint id [[vertex_id]],
      const device Vertex* vertices [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
      Varying out;
      out.position = u.mvp * vertices[id].position;
      out.normal = (u.normalMatrix * vertices[id].normal).xyz;
      return out;
    }
    struct Fragment { half4 color [[color(0)]]; half coverage [[color(1)]]; };
    fragment Fragment meshFragment(Varying in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
      float diffuse = max(0.0f, dot(normalize(in.normal), u.light.xyz));
      float3 rgb = clamp(u.color.rgb * (u.ambient.x + diffuse * u.light.w), 0.0f, 1.0f);
      Fragment out;
      out.color = half4(half3(rgb), half(1));
      out.coverage = half(1);
      return out;
    }
    """
}
