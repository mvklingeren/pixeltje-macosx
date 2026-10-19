// Offline preview renderer for GPU Program shaders; see AGENTS.md, "Offline
// render previews". render-preview.sh compiles it together with the engine's
// own Metal library and system-font sources, so source resolution and HUD
// fonts match the app. The pass loop mirrors PipelineGPUProgram.
//
// usage: render-preview.sh <workflow.pixpipeline.json> <views.json> <out-dir>
//          [--node <gpu.program node id>] [--before <old.metal>]
//
// The views file (relative texture paths resolve beside it):
//   { "width": 960, "height": 540,                    optional size override
//     "textures": { "<asset port>": "image.png" },    optional; grey if absent
//     "views": [ { "name": "start",
//       "frames": 1,               ticks before present; 0 = initialize only
//       "pointer": [x, y, actionCount, dt], "movement": [x, y, secondary, 0],
//       "parameters": { "name": 1.0 },       overrides the workflow's values
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
    let instanceCount: Int?
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
    let name: String
    let frames: Int?
    let pointer: [Float]?
    let movement: [Float]?
    let parameters: [String: Float]?
    let writes: [Write]?
  }
  let width: Int?
  let height: Int?
  let textures: [String: String]?
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
guard arguments.count == 3 else {
  FileHandle.standardError.write(Data("""
    usage: render-preview.sh <workflow.pixpipeline.json> <views.json> <out-dir> \
    [--node <id>] [--before <old.metal>]\n
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

func sibling(_ name: String) throws -> String {
  try String(contentsOf: workflowFolder.appendingPathComponent(name), encoding: .utf8)
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
      return output["port"] as? String == "contents" ? try sibling(name) : name
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
let width = try views.width
  ?? (value(into: programNodeID, port: "width") as? NSNumber)?.intValue ?? 960
let height = try views.height
  ?? (value(into: programNodeID, port: "height") as? NSNumber)?.intValue ?? 540
let fps = (unwrap(nodeParameters["framesPerSecond"]) as? NSNumber)?.doubleValue ?? 60
let seed = (unwrap(nodeParameters["seed"]) as? NSNumber)?.uint64Value ?? 1
var workflowValues: [String: Float] = [:]
if let json = try value(into: programNodeID, port: "parameters") as? String,
  let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber] {
  workflowValues = object.mapValues(\.floatValue)
}

// MARK: Shader source

// Mirrors PipelineMeshRenderer: one level of #include "Sibling.metal".
func expandIncludes(_ source: String) throws -> String {
  try source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#include \""), trimmed.hasSuffix("\"") else { return String(line) }
    return try sibling(String(trimmed.dropFirst(10).dropLast()))
  }.joined(separator: "\n")
}

func currentSource() throws -> String {
  if let inline = try value(into: programNodeID, port: "source") as? String { return inline }
  guard let name = try value(into: programNodeID, port: "sourceFile") as? String else {
    throw Failure(description: "The GPU Program has no source or sourceFile input.")
  }
  return try sibling(name)
}

// MARK: Rendering

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

enum Resource {
  case buffer(any MTLBuffer)
  case texture(any MTLTexture)
}

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
  return Uniforms(
    resolutionTime: SIMD4(Float(width), Float(height), Float(Double(frame) / fps), Float(1 / fps)),
    frameSeed: SIMD4(UInt32(frame), UInt32(truncatingIfNeeded: seed),
      UInt32(truncatingIfNeeded: seed >> 32), 0),
    parameters: (group(0), group(4), group(8), group(12)),
    pointer: vector(view.pointer ?? [0.5, 0.5, 0, 0]),
    movement: vector(view.movement))
}

final class Renderer {
  let library: any MTLLibrary
  var computePipelines: [String: any MTLComputePipelineState] = [:]
  var renderPipelines: [String: any MTLRenderPipelineState] = [:]

  init(source: String) throws {
    library = try device.makeLibrary(
      source: PipelineMetalLibraries.resolving(try expandIncludes(source)), options: nil)
  }

  func encode(_ passes: [Program.Pass], resources: [String: Resource], uniforms: Uniforms) throws {
    let command = queue.makeCommandBuffer()!
    var uniforms = uniforms
    func buffers(_ mapping: [String: String]?, _ set: (any MTLBuffer, Int) -> Void) {
      for (slot, name) in mapping ?? [:] {
        if let index = Int(slot), case .buffer(let buffer)? = resources[name] { set(buffer, index) }
      }
    }
    func textures(_ mapping: [String: String]?, _ set: (any MTLTexture, Int) -> Void) {
      for (slot, name) in mapping ?? [:] {
        if let index = Int(slot), case .texture(let texture)? = resources[name] { set(texture, index) }
      }
    }
    for pass in passes {
      if pass.kind == "compute" {
        let name = pass.function!
        guard let function = library.makeFunction(name: name) else {
          throw Failure(description: "Missing compute function \(name).")
        }
        let pipeline = try computePipelines[name]
          ?? device.makeComputePipelineState(function: function)
        computePipelines[name] = pipeline
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
          if blend != "replace" {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = blend == "alpha" ? .sourceAlpha : .one
            attachment.destinationRGBBlendFactor = blend == "alpha" ? .oneMinusSourceAlpha : .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = blend == "alpha" ? .oneMinusSourceAlpha : .one
          }
          pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
          renderPipelines[key] = pipeline
        }
        let render = MTLRenderPassDescriptor()
        render.colorAttachments[0].texture = target
        render.colorAttachments[0].loadAction = pass.load == "load" ? .load : .clear
        render.colorAttachments[0].storeAction = .store
        render.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let encoder = command.makeRenderCommandEncoder(descriptor: render)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        buffers(pass.vertexBuffers) { encoder.setVertexBuffer($0, offset: 0, index: $1) }
        buffers(pass.fragmentBuffers) { encoder.setFragmentBuffer($0, offset: 0, index: $1) }
        textures(pass.vertexTextures) { encoder.setVertexTexture($0, index: $1) }
        textures(pass.fragmentTextures) { encoder.setFragmentTexture($0, index: $1) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
          vertexCount: pass.vertexCount!, instanceCount: pass.instanceCount ?? 1)
        encoder.endEncoding()
      }
    }
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
  }

  // Returns 8-bit RGBA rows of the output texture, whose values the engine
  // reads as sRGB-encoded 0–1.
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
    for write in view.writes ?? [] {
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
      if let floats = write.floats { floats.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
      if let uints = write.uints { uints.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    }
    try encode(program.present, resources: resources,
      uniforms: uniforms(frame: max(frames - 1, 0), view: view))
    guard case .texture(let output)? = resources[program.output] else {
      throw Failure(description: "Program output \(program.output) is not a texture.")
    }
    var half = [Float16](repeating: 0, count: width * height * 4)
    output.getBytes(&half, bytesPerRow: width * 8,
      from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
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
let current = try Renderer(source: currentSource())
let before = try beforePath.map {
  try Renderer(source: String(contentsOfFile: $0, encoding: .utf8))
}
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
