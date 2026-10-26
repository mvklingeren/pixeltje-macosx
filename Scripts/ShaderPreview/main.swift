// Offline preview renderer for GPU Program shaders; see AGENTS.md, "Offline
// render previews". render-preview.sh compiles it together with the engine's
// own Metal library and system-font sources, so source resolution and HUD
// fonts match the app. The pass loop mirrors PipelineGPUProgram.
//
// usage: render-preview.sh <workflow.pixpipeline.json> <views.json> <out-dir>
//          [--node <gpu.program node id>] [--before <old.metal>]
//          [--dump-source <resolved.metal>]
//
// PIXELTJE_PREVIEW_SIZE=1440x900 overrides the views file's size.
// PIXELTJE_PASS_TIMINGS=<runs> times every view after its image is taken: it
// runs present that many more times, each pass in its own command buffer, then
// one more tick the same way, and prints each pass's median GPU time. Pass
// timings include one command buffer's overhead each, so compare them with
// one another rather than with an app frame.
//
// PIXELTJE_DUMP_BUFFERS=game,audio writes those buffers' bytes after present
// to <out-dir>/<view>.<buffer>.bin.
//
// The views file (relative texture paths resolve beside it):
//   { "width": 960, "height": 540,                    optional size override
//     "textures": { "<asset port>": "image.png" },    optional; grey if absent
//     "models": { "<asset port>": "~/model.fbx" },    optional; otherwise the
//                        workflow's Load Skinned Model node behind that asset
//     "views": [ { "name": "start",
//       "frames": 1,               ticks before present; 0 = initialize only
//       "pointer": [x, y, actionCount, dt], "movement": [x, y, secondary, keys],
//       "inputs": [{ "frame": 20, "pointer": [x, y, 1, dt] }],
//       "parameters": { "name": 1.0 },       overrides the workflow's values
//       "initialWrites": [ { "buffer": "game", "offset": 0,
//                            "floats": [ ... ] } ],
//       "writes": [ { "buffer": "game", "offset": 0, "floats": [ ... ] },
//                   { "buffer": "game", "offset": 32, "uints": [ ... ] } ]
//     } ] }
// Writes land after the ticks and before present, so a view can place the
// camera or set game state directly. Each view becomes <out-dir>/<name>.png;
// with --before it shows the old source on the left and the current on the
// right.
import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers

// PipelineSystemFont reports errors through the engine's error type.
enum PipelineEngineError: Error { case invalidInvocation(String) }

struct Failure: Error, CustomStringConvertible { let description: String }

struct Program: Decodable {
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
    let vertexCountFrom: String?
    let instanceCount: Int?
    let depth: String?
    let buffers: [String: String]?
    let textures: [String: String]?
    let vertexBuffers: [String: String]?
    let fragmentBuffers: [String: String]?
    let vertexTextures: [String: String]?
    let fragmentTextures: [String: String]?
  }
  struct AudioEvent: Decodable { let buffer: String; let word: Int? }
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

struct Views: Decodable {
  struct Write: Decodable {
    let buffer: String
    let offset: Int?
    let floats: [Float]?
    let uints: [UInt32]?
  }
  struct View: Decodable {
    struct Input: Decodable {
      let frame: Int
      let pointer: [Float]?
      let movement: [Float]?
    }
    let name: String
    let frames: Int?
    let pointer: [Float]?
    let movement: [Float]?
    let inputs: [Input]?
    let parameters: [String: Float]?
    let initialWrites: [Write]?
    let writes: [Write]?
  }
  let width: Int?
  let height: Int?
  let textures: [String: String]?
  let models: [String: String]?
  let views: [View]
}

struct Uniforms {
  var resolutionTime: SIMD4<Float>
  var frameSeed: SIMD4<UInt32>
  var parameters: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
  var pointer: SIMD4<Float>
  var movement: SIMD4<Float>
}

func vector(_ values: [Float]?) -> SIMD4<Float> {
  var result = SIMD4<Float>.zero
  for (index, value) in (values ?? []).prefix(4).enumerated() { result[index] = value }
  return result
}

// Workflow parameters are either plain values or {"$type", "value"} wrappers.
func unwrap(_ value: Any?) -> Any? {
  if let wrapper = value as? [String: Any], let inner = wrapper["value"] { return unwrap(inner) }
  return value
}

// MARK: Arguments and workflow

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  defer { arguments.removeSubrange(index...(index + 1)) }
  return arguments[index + 1]
}
let nodeOption = option("--node")
let beforePath = option("--before")
let dumpSourcePath = option("--dump-source")
guard arguments.count == 3 else {
  FileHandle.standardError.write(Data("""
    usage: render-preview.sh <workflow.pixpipeline.json> <views.json> <out-dir> \
    [--node <id>] [--before <old.metal>] [--dump-source <resolved.metal>]\n
    """.utf8))
  exit(64)
}
let workflowURL = URL(fileURLWithPath: arguments[0])
let viewsURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let workflowFolder = workflowURL.deletingLastPathComponent()

let workflow = try JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as! [String: Any]
let nodes = workflow["nodes"] as! [[String: Any]]
let connections = workflow["connections"] as! [[String: Any]]
let programNodes = nodes.filter {
  $0["kind"] as? String == "gpu.program" && (nodeOption == nil || $0["id"] as? String == nodeOption)
}
guard programNodes.count == 1, let programNode = programNodes.first,
  let programNodeID = programNode["id"] as? String else {
  throw Failure(description: "Expected exactly one gpu.program node; pass --node <id>.")
}
let nodeParameters = programNode["parameters"] as? [String: Any] ?? [:]

func filePathContents(_ path: String, mode: String) throws -> String {
  guard !path.isEmpty, !path.contains("\0") else {
    throw Failure(description: "File Path needs a nonempty path.")
  }
  let absolute = (path as NSString).isAbsolutePath
  let url: URL
  switch mode {
  case "relative" where !absolute:
    let root = workflowFolder.resolvingSymlinksInPath().standardizedFileURL
    url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.path.hasPrefix(prefix) else {
      throw Failure(description: "File Path contents must stay inside the workflow folder.")
    }
  case "absolute" where absolute:
    url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
  default:
    throw Failure(description: "File Path mode and path do not match.")
  }
  guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
    attributes.isRegularFile == true, let size = attributes.fileSize,
    size <= 4_194_304 else {
    throw Failure(description: "File Path contents need a regular UTF-8 file of at most 4 MiB.")
  }
  let data = try Data(contentsOf: url)
  guard data.count <= 4_194_304, let source = String(data: data, encoding: .utf8) else {
    throw Failure(description: "File Path contents need a UTF-8 file of at most 4 MiB.")
  }
  return source
}

func metalSibling(_ name: String) throws -> (source: String, canonicalPath: String) {
  guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
    name != ".", name != "..", name.hasSuffix(".metal") else {
    throw Failure(description: "Metal includes must name a .metal file beside the workflow.")
  }
  let root = workflowFolder.resolvingSymlinksInPath().standardizedFileURL
  let url = workflowFolder.appendingPathComponent(name).resolvingSymlinksInPath()
    .standardizedFileURL
  guard url.deletingLastPathComponent() == root,
    let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
    attributes.isRegularFile == true,
    let fileSize = attributes.fileSize, (1...4_194_304).contains(fileSize) else {
    throw Failure(description: "Metal source file must be a nonempty .metal file of at most 4 MiB beside the workflow.")
  }
  let data = try Data(contentsOf: url)
  guard !data.isEmpty, data.count <= 4_194_304,
    let source = String(data: data, encoding: .utf8) else {
    throw Failure(description: "Metal source file must contain 1 to 4,194,304 UTF-8 bytes.")
  }
  return (source, url.path)
}

// The value arriving at a node's input, followed through primitive nodes: a
// file path node yields its name, or its text from the "contents" port, and a
// primitive whose own value input is connected passes that value on.
func value(into nodeID: String, port: String) throws -> Any? {
  for connection in connections {
    guard let input = connection["input"] as? [String: Any],
      input["nodeID"] as? String == nodeID, input["port"] as? String == port,
      let output = connection["output"] as? [String: Any],
      let id = output["nodeID"] as? String,
      let node = nodes.first(where: { $0["id"] as? String == id }) else { continue }
    let parameters = node["parameters"] as? [String: Any] ?? [:]
    if node["kind"] as? String == "primitive.filePath",
      let name = unwrap(parameters["path"]) as? String {
      let mode = unwrap(parameters["mode"]) as? String ?? "relative"
      return output["port"] as? String == "contents"
        ? try filePathContents(name, mode: mode) : name
    }
    return try value(into: id, port: "value") ?? unwrap(parameters["value"])
  }
  return nil
}

guard let programJSON = try value(into: programNodeID, port: "program") as? String else {
  throw Failure(description: "The program input must come from primitive nodes.")
}
let program = try JSONDecoder().decode(Program.self, from: Data(programJSON.utf8))
let views = try JSONDecoder().decode(Views.self, from: Data(contentsOf: viewsURL))
let sizeOverride = ProcessInfo.processInfo.environment["PIXELTJE_PREVIEW_SIZE"]
  .map { $0.split(separator: "x").compactMap { Int($0) } }
  .flatMap { $0.count == 2 ? $0 : nil }
let width = try sizeOverride?[0] ?? views.width
  ?? (value(into: programNodeID, port: "width") as? NSNumber)?.intValue ?? 960
let height = try sizeOverride?[1] ?? views.height
  ?? (value(into: programNodeID, port: "height") as? NSNumber)?.intValue ?? 540
let timingRuns = Int(ProcessInfo.processInfo.environment["PIXELTJE_PASS_TIMINGS"] ?? "") ?? 0
let fps = (unwrap(nodeParameters["framesPerSecond"]) as? NSNumber)?.doubleValue ?? 60
let seed = (unwrap(nodeParameters["seed"]) as? NSNumber)?.uint64Value ?? 1
var workflowValues: [String: Float] = [:]
if let json = try value(into: programNodeID, port: "parameters") as? String,
  let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber] {
  workflowValues = object.mapValues(\.floatValue)
}

// The FBX behind a skinnedModel asset: the views file's own path, or the path
// feeding the Load Skinned Model node that fills that Asset Cache slot.
func skinnedModel(port: String, programID: String) throws -> PipelineSkinnedModel {
  var path = views.models?[port]
  var parameters: [String: Any] = [:]
  var root = viewsURL.deletingLastPathComponent()
  if path == nil {
    for connection in connections {
      guard let input = connection["input"] as? [String: Any],
        input["port"] as? String == port,
        let cacheID = input["nodeID"] as? String,
        connections.contains(where: {
          ($0["input"] as? [String: Any])?["nodeID"] as? String == programID
            && ($0["output"] as? [String: Any])?["nodeID"] as? String == cacheID
        }),
        let output = connection["output"] as? [String: Any],
        let loaderID = output["nodeID"] as? String,
        let loader = nodes.first(where: { $0["id"] as? String == loaderID }),
        loader["kind"] as? String == "geometry.loadSkinnedModel" else { continue }
      path = try value(into: loaderID, port: "path") as? String
      parameters = loader["parameters"] as? [String: Any] ?? [:]
      root = workflowFolder
    }
  }
  guard let path else {
    throw Failure(description: "No skinned model for asset \(port); add it to the views file's models.")
  }
  let url = try PipelineSkinnedModelLoader.url(for: path, sourceMediaRoot: root)
  return try PipelineSkinnedModelLoader.model(at: url,
    animation: unwrap(parameters["animation"]) as? String ?? "",
    framesPerSecond: (unwrap(parameters["framesPerSecond"]) as? NSNumber)?.doubleValue ?? 30,
    rootMotion: PipelineSkinnedModel.RootMotion(
      rawValue: unwrap(parameters["rootMotion"]) as? String ?? "inPlace") ?? .inPlace)
}

let skinnedModels = try Dictionary(uniqueKeysWithValues: program.resources
  .filter { $0.kind == "skinnedModel" }
  .map { ($0.name, try skinnedModel(port: $0.input ?? $0.name, programID: programNodeID)) })

// MARK: Shader source

// Mirrors PipelineMeshRenderer: recursive #include "Sibling.metal" with
// #pragma once, cycle detection, and #line directives.
func expandIncludes(
  _ source: String, fileName: String = "<source>",
  identity: String,
  activeStack: inout [String], includedOnce: inout Set<String>,
  includeCount: inout Int
) throws -> String {
  guard activeStack.count <= 16 else {
    throw Failure(description: "Metal local includes exceed the maximum nesting depth of 16.")
  }
  if includedOnce.contains(identity) { return "" }
  if activeStack.contains(identity) {
    let chain = (activeStack + [identity]).map { URL(fileURLWithPath: $0).lastPathComponent }
      .joined(separator: " -> ")
    throw Failure(description: "Metal local includes form a cycle: \(chain).")
  }
  let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false)
  if rawLines.contains(where: {
    $0.trimmingCharacters(in: .whitespacesAndNewlines) == "#pragma once"
  }) {
    includedOnce.insert(identity)
  }
  activeStack.append(identity)
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
      throw Failure(description: "Malformed local include in \(fileName):\(lineNumber).")
    }
    includeCount += 1
    guard includeCount <= 64 else {
      throw Failure(description: "Metal local includes exceed 64 expansions.")
    }
    let childName = String(trimmed.dropFirst(10).dropLast())
    let child = try metalSibling(childName)
    let included = try expandIncludes(
      child.source, fileName: childName, identity: child.canonicalPath,
      activeStack: &activeStack, includedOnce: &includedOnce,
      includeCount: &includeCount)
    if !included.isEmpty {
      lines.append(included)
    }
    lines.append(PipelineMetalLibraries.lineDirective(lineNumber + 1, fileName: fileName))
  }
  let expanded = lines.joined(separator: "\n")
  guard expanded.utf8.count <= 8_388_608 else {
    throw Failure(description: "Metal source and includes exceed 8,388,608 UTF-8 bytes.")
  }
  return expanded
}

func expandIncludes(_ source: String, fileName: String, identity: String) throws -> String {
  var activeStack: [String] = []
  var includedOnce: Set<String> = []
  var includeCount = 0
  return try expandIncludes(
    source, fileName: fileName, identity: identity,
    activeStack: &activeStack, includedOnce: &includedOnce,
    includeCount: &includeCount)
}

func currentSource() throws -> (source: String, fileName: String, identity: String,
  expandsIncludes: Bool) {
  if let inline = try value(into: programNodeID, port: "source") as? String {
    return (inline, "<source>", "<source>", false)
  }
  guard let name = try value(into: programNodeID, port: "sourceFile") as? String else {
    throw Failure(description: "The GPU Program has no source or sourceFile input.")
  }
  let file = try metalSibling(name)
  return (file.source, name, file.canonicalPath, true)
}

if let dumpSourcePath {
  let (text, fileName, identity, expandsIncludes) = try currentSource()
  let expanded = try expandsIncludes
    ? expandIncludes(text, fileName: fileName, identity: identity) : text
  let resolved = PipelineMetalLibraries.resolving(expanded)
  try resolved.write(toFile: dumpSourcePath, atomically: true, encoding: .utf8)
  exit(0)
}

// MARK: Rendering

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

enum Resource {
  case buffer(any MTLBuffer)
  case texture(any MTLTexture)
  case model(any MTLBuffer, texture: any MTLTexture, vertexCount: Int)
  case depth(any MTLTexture)
}

let depthState: any MTLDepthStencilState = {
  let descriptor = MTLDepthStencilDescriptor()
  descriptor.depthCompareFunction = .lessEqual
  descriptor.isDepthWriteEnabled = true
  return device.makeDepthStencilState(descriptor: descriptor)!
}()

func makeTexture(width: Int, height: Int, usage: MTLTextureUsage) -> any MTLTexture {
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
    width: width, height: height, mipmapped: false)
  descriptor.storageMode = .shared
  descriptor.usage = usage
  return device.makeTexture(descriptor: descriptor)!
}

// Input images are read as sRGB-encoded 0–1 values, like the engine's assets.
func inputTexture(port: String) throws -> any MTLTexture {
  var image: CGImage?
  if let path = views.textures?[port] {
    let url = URL(fileURLWithPath: path, relativeTo: viewsURL.deletingLastPathComponent())
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw Failure(description: "Cannot read texture \(url.path).")
    }
    image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  } else {
    print("note: no image for asset \(port); using mid grey")
  }
  let w = image?.width ?? 256, h = image?.height ?? 256
  var bytes = [UInt8](repeating: 128, count: w * h * 4)
  if let image {
    let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  let half = bytes.map { Float16(Float($0) / 255) }
  let texture = makeTexture(width: w, height: h, usage: [.shaderRead])
  half.withUnsafeBytes {
    texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: w * 8)
  }
  return texture
}

func makeResources() throws -> [String: Resource] {
  var result: [String: Resource] = [:]
  for item in program.resources {
    switch item.kind {
    case "buffer":
      let buffer = device.makeBuffer(length: item.bytes!, options: .storageModeShared)!
      memset(buffer.contents(), 0, buffer.length)
      result[item.name] = .buffer(buffer)
    case "systemFont":
      let prepared = try PipelineSystemFont.prepare(design: item.design!,
        weight: item.weight!, strings: item.strings!)
      result[item.name] = .buffer(prepared.bytes.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
      })
    case "inputTexture":
      result[item.name] = .texture(try inputTexture(port: item.input ?? item.name))
    case "skinnedModel":
      let model = skinnedModels[item.name]!
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm_srgb, width: model.textureWidth,
        height: model.textureHeight, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = [.shaderRead]
      let texture = device.makeTexture(descriptor: descriptor)!
      model.textureRGBA8.withUnsafeBytes { pixels in
        texture.replace(region: MTLRegionMake2D(0, 0,
          model.textureWidth, model.textureHeight), mipmapLevel: 0,
          withBytes: pixels.baseAddress!, bytesPerRow: model.textureWidth * 4)
      }
      result[item.name] = .model(model.bytes.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
      }, texture: texture, vertexCount: model.vertexCount)
    case "depth":
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
        width: width, height: height, mipmapped: false)
      descriptor.storageMode = .private
      descriptor.usage = [.renderTarget]
      result[item.name] = .depth(device.makeTexture(descriptor: descriptor)!)
    default:
      result[item.name] = .texture(makeTexture(width: width, height: height,
        usage: [.shaderRead, .shaderWrite, .renderTarget]))
    }
  }
  return result
}

func uniforms(frame: Int, view: Views.View) -> Uniforms {
  let values = workflowValues.merging(view.parameters ?? [:]) { $1 }
  var numbers = [Float](repeating: 0, count: 16)
  for (index, name) in (program.parameters ?? []).prefix(16).enumerated() {
    numbers[index] = values[name] ?? 0
  }
  func group(_ start: Int) -> SIMD4<Float> { vector(Array(numbers[start..<(start + 4)])) }
  let input = view.inputs?.filter { $0.frame <= frame }
    .max { $0.frame < $1.frame }
  return Uniforms(
    resolutionTime: SIMD4(Float(width), Float(height), Float(Double(frame) / fps), Float(1 / fps)),
    frameSeed: SIMD4(UInt32(frame), UInt32(truncatingIfNeeded: seed),
      UInt32(truncatingIfNeeded: seed >> 32), 0),
    parameters: (group(0), group(4), group(8), group(12)),
    pointer: vector(input?.pointer ?? view.pointer ?? [0.5, 0.5, 0, 0]),
    movement: vector(input?.movement ?? view.movement))
}

final class Renderer {
  let library: any MTLLibrary
  var computePipelines: [String: any MTLComputePipelineState] = [:]
  var renderPipelines: [String: any MTLRenderPipelineState] = [:]
  var label = "current"

  init(source: String, fileName: String = "<source>", identity: String = "<source>",
    expandsIncludes: Bool = true) throws {
    let expanded = try expandsIncludes
      ? expandIncludes(source, fileName: fileName, identity: identity) : source
    library = try device.makeLibrary(
      source: PipelineMetalLibraries.resolving(expanded), options: nil)
  }

  /// Returns the command buffer's GPU time in milliseconds.
  @discardableResult
  func encode(_ passes: [Program.Pass], resources: [String: Resource], uniforms: Uniforms) throws
    -> Double {
    let command = queue.makeCommandBuffer()!
    var uniforms = uniforms
    func buffers(_ mapping: [String: String]?, _ set: (any MTLBuffer, Int) -> Void) {
      for (slot, name) in mapping ?? [:] {
        guard let index = Int(slot) else { continue }
        switch resources[name] {
        case .buffer(let buffer)?, .model(let buffer, _, _)?: set(buffer, index)
        default: break
        }
      }
    }
    func textures(_ mapping: [String: String]?, _ set: (any MTLTexture, Int) -> Void) {
      for (slot, name) in mapping ?? [:] {
        guard let index = Int(slot) else { continue }
        switch resources[name] {
        case .texture(let texture)?, .model(_, let texture, _)?: set(texture, index)
        default: break
        }
      }
    }
    for pass in passes {
      if pass.kind == "compute" {
        let name = pass.function!
        guard let function = library.makeFunction(name: name) else {
          throw Failure(description: "Missing compute function \(name).")
        }
        let pipeline: any MTLComputePipelineState
        if let cached = computePipelines[name] { pipeline = cached } else {
          let start = ProcessInfo.processInfo.systemUptime
          pipeline = try device.makeComputePipelineState(function: function)
          if ProcessInfo.processInfo.environment["PIXELTJE_SHADER_TIMINGS"] == "1" {
            let seconds = String(format: "%.3f",
              ProcessInfo.processInfo.systemUptime - start)
            print("cold pipeline \(name): \(seconds) s")
          }
          computePipelines[name] = pipeline
        }
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        buffers(pass.buffers) { encoder.setBuffer($0, offset: 0, index: $1) }
        textures(pass.textures) { encoder.setTexture($0, index: $1) }
        let threads = pass.threads!
        encoder.dispatchThreads(MTLSize(width: threads[0],
          height: threads.count > 1 ? threads[1] : 1, depth: threads.count > 2 ? threads[2] : 1),
          threadsPerThreadgroup: MTLSize(width: min(pipeline.threadExecutionWidth, threads[0]),
            height: 1, depth: 1))
        encoder.endEncoding()
      } else {
        guard case .texture(let target)? = resources[pass.target!] else {
          throw Failure(description: "Render target \(pass.target!) is not a texture.")
        }
        let blend = pass.blend ?? "replace"
        let key = "\(pass.vertex!)|\(pass.fragment!)|\(blend)"
          + (pass.depth == nil ? "" : "|depth")
        let pipeline: any MTLRenderPipelineState
        if let cached = renderPipelines[key] { pipeline = cached } else {
          guard let vertex = library.makeFunction(name: pass.vertex!),
            let fragment = library.makeFunction(name: pass.fragment!) else {
            throw Failure(description: "Missing render function in \(key).")
          }
          let descriptor = MTLRenderPipelineDescriptor()
          descriptor.vertexFunction = vertex
          descriptor.fragmentFunction = fragment
          let attachment = descriptor.colorAttachments[0]!
          attachment.pixelFormat = .rgba16Float
          if pass.depth != nil { descriptor.depthAttachmentPixelFormat = .depth32Float }
          if blend != "replace" {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = blend == "alpha" ? .sourceAlpha : .one
            attachment.destinationRGBBlendFactor = blend == "alpha" ? .oneMinusSourceAlpha : .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = blend == "alpha" ? .oneMinusSourceAlpha : .one
          }
          let start = ProcessInfo.processInfo.systemUptime
          pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
          if ProcessInfo.processInfo.environment["PIXELTJE_SHADER_TIMINGS"] == "1" {
            let seconds = String(format: "%.3f",
              ProcessInfo.processInfo.systemUptime - start)
            print("cold pipeline \(key): \(seconds) s")
          }
          renderPipelines[key] = pipeline
        }
        let render = MTLRenderPassDescriptor()
        render.colorAttachments[0].texture = target
        render.colorAttachments[0].loadAction = pass.load == "load" ? .load : .clear
        render.colorAttachments[0].storeAction = .store
        render.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if let name = pass.depth, case .depth(let depth)? = resources[name] {
          render.depthAttachment.texture = depth
          render.depthAttachment.loadAction = pass.load == "load" ? .load : .clear
          render.depthAttachment.storeAction = .store
          render.depthAttachment.clearDepth = 1
        }
        let encoder = command.makeRenderCommandEncoder(descriptor: render)!
        encoder.setRenderPipelineState(pipeline)
        if pass.depth != nil { encoder.setDepthStencilState(depthState) }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        buffers(pass.vertexBuffers) { encoder.setVertexBuffer($0, offset: 0, index: $1) }
        buffers(pass.fragmentBuffers) { encoder.setFragmentBuffer($0, offset: 0, index: $1) }
        textures(pass.vertexTextures) { encoder.setVertexTexture($0, index: $1) }
        textures(pass.fragmentTextures) { encoder.setFragmentTexture($0, index: $1) }
        var vertexCount = pass.vertexCount ?? 0
        if let name = pass.vertexCountFrom, case .model(_, _, let count)? = resources[name] {
          vertexCount = count
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
          vertexCount: vertexCount, instanceCount: pass.instanceCount ?? 1)
        encoder.endEncoding()
      }
    }
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    return (command.gpuEndTime - command.gpuStartTime) * 1000
  }

  /// Median GPU milliseconds of each pass over runs, each pass alone in its
  /// own command buffer, in program order.
  func timePasses(_ passes: [Program.Pass], runs: Int, resources: [String: Resource],
    uniforms: Uniforms) throws -> [(name: String, milliseconds: Double)] {
    var samples = [[Double]](repeating: [], count: passes.count)
    for _ in 0..<runs {
      for (index, pass) in passes.enumerated() {
        samples[index].append(try encode([pass], resources: resources, uniforms: uniforms))
      }
    }
    return zip(passes, samples).map { pass, times in
      (pass.function ?? pass.fragment ?? "?", times.sorted()[times.count / 2])
    }
  }

  // Returns 8-bit RGBA rows of the output texture, whose values the engine
  // reads as sRGB-encoded 0–1.
  func applyWrites(_ writes: [Views.Write]?, resources: [String: Resource]) throws {
    for write in writes ?? [] {
      guard case .buffer(let buffer)? = resources[write.buffer] else {
        throw Failure(description: "Write target \(write.buffer) is not a buffer.")
      }
      let offset = write.offset ?? 0
      let bytes = (write.floats ?? []).count * 4 + (write.uints ?? []).count * 4
      guard offset >= 0, offset + bytes <= buffer.length,
        (write.floats == nil) != (write.uints == nil) else {
        throw Failure(description: "Write to \(write.buffer) needs floats or uints within its \(buffer.length) bytes.")
      }
      let destination = buffer.contents() + offset
      if let floats = write.floats {
        floats.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
      }
      if let uints = write.uints {
        uints.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
      }
    }
  }

  func render(_ view: Views.View) throws -> [UInt8] {
    var resources = try makeResources()
    let clear = queue.makeCommandBuffer()!
    for case .texture(let texture) in resources.values where texture.usage.contains(.renderTarget) {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      clear.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
    }
    clear.commit()
    clear.waitUntilCompleted()
    try encode(program.initialize, resources: resources, uniforms: uniforms(frame: 0, view: view))
    try applyWrites(view.initialWrites, resources: resources)
    let frames = max(view.frames ?? 1, 0)
    for index in 0..<frames {
      if let name = program.sceneRequestBuffer, case .buffer(let buffer)? = resources[name] {
        buffer.contents().storeBytes(of: UInt32.max, as: UInt32.self)
      }
      for event in program.audioEvents ?? [] {
        if case .buffer(let buffer)? = resources[event.buffer] {
          buffer.contents().storeBytes(of: UInt32.zero,
            toByteOffset: (event.word ?? 0) * 4, as: UInt32.self)
        }
      }
      try encode(program.tick, resources: resources, uniforms: uniforms(frame: index, view: view))
      for pair in program.swaps {
        let first = resources[pair[0]]
        resources[pair[0]] = resources[pair[1]]
        resources[pair[1]] = first
      }
    }
    try applyWrites(view.writes, resources: resources)
    try encode(program.present, resources: resources,
      uniforms: uniforms(frame: max(frames - 1, 0), view: view))
    guard case .texture(let output)? = resources[program.output] else {
      throw Failure(description: "Program output \(program.output) is not a texture.")
    }
    var half = [Float16](repeating: 0, count: width * height * 4)
    output.getBytes(&half, bytesPerRow: width * 8,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    for name in (ProcessInfo.processInfo.environment["PIXELTJE_DUMP_BUFFERS"] ?? "")
      .split(separator: ",").map(String.init) {
      guard case .buffer(let buffer)? = resources[name] else { continue }
      try Data(bytes: buffer.contents(), count: buffer.length).write(to:
        outputDirectory.appendingPathComponent("\(view.name).\(name).bin"))
    }
    if timingRuns > 0 {
      let frame = max(frames - 1, 0)
      let present = try timePasses(program.present, runs: timingRuns,
        resources: resources, uniforms: uniforms(frame: frame, view: view))
      let tick = try timePasses(program.tick, runs: 1,
        resources: resources, uniforms: uniforms(frame: frames, view: view))
      func line(_ timings: [(name: String, milliseconds: Double)]) -> String {
        timings.map { "\($0.name)=\(String(format: "%.2f", $0.milliseconds))" }
          .joined(separator: " ")
      }
      let total = present.reduce(0) { $0 + $1.milliseconds }
      let tickTotal = tick.reduce(0) { $0 + $1.milliseconds }
      print("timing \(label) \(view.name) present=\(String(format: "%.2f", total)) ms "
        + "tick=\(String(format: "%.2f", tickTotal)) ms | \(line(present)) | \(line(tick))")
    }
    return half.map { UInt8((min(max(Float($0), 0), 1) * 255).rounded()) }
  }
}

func writePNG(_ rgba: [UInt8], width: Int, to url: URL) {
  let height = rgba.count / (width * 4)
  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
    provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil,
    shouldInterpolate: false, intent: .defaultIntent)!
  let destination = CGImageDestinationCreateWithURL(url as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let (currentText, currentFileName, currentIdentity, currentExpandsIncludes) = try currentSource()
let current = try Renderer(source: currentText, fileName: currentFileName,
  identity: currentIdentity, expandsIncludes: currentExpandsIncludes)
let before = try beforePath.map {
  try Renderer(
    source: String(contentsOfFile: $0, encoding: .utf8),
    fileName: URL(fileURLWithPath: $0).lastPathComponent,
    identity: URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path)
}
before?.label = "before"
for view in views.views {
  var image = try current.render(view)
  var imageWidth = width
  if let before {
    // Old source on the left, current on the right, an 8-pixel black gap between.
    let old = try before.render(view)
    let gap = [UInt8](repeating: 0, count: 8 * 4)
    image = (0..<height).flatMap { row in
      old[(row * width * 4)..<((row + 1) * width * 4)] + gap
        + image[(row * width * 4)..<((row + 1) * width * 4)]
    }
    imageWidth = width * 2 + 8
  }
  let url = outputDirectory.appendingPathComponent("\(view.name).png")
  writePNG(image, width: imageWidth, to: url)
  print(url.path)
}
