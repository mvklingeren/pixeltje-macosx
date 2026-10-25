// The Shader Preview harness compiles this file on its own, so it depends
// only on ufbx and Apple frameworks; see Scripts/ShaderPreview.
import CUFBX
import CryptoKit
import Foundation
import simd
import Synchronization

/// A skinned, animated triangle model packed for one read-only GPU buffer.
/// Positions are meters in a right-handed, +Y-up space with the model's feet
/// on y = 0 and its first frame centred on x = z = 0.
///
/// The bytes a GPU Program `skinnedModel` resource receives, little-endian:
///
/// ```metal
/// struct SkinnedModelHeader {      // 64 bytes
///   uint vertexCount;              // triangle list, a multiple of 3
///   uint boneCount;
///   uint frameCount;               // frames sampled over one loop
///   float framesPerSecond;
///   float4 boundsMin;              // first frame; w = loop seconds
///   float4 boundsMax;
///   uint verticesOffset;           // bytes from the start of the buffer
///   uint framesOffset;
///   uint2 reserved;
/// };
/// struct SkinnedVertex {           // 48 bytes, bind pose
///   packed_float3 position;
///   uint color;                    // RGBA8 unorm material colour
///   packed_float3 normal;
///   uint joints;                   // four 8-bit bone indices
///   float4 weights;                // sum to 1
/// };
/// // frameCount * boneCount float4x4 skinning matrices, frame-major. Each
/// // maps a bind-pose position to the model space of that frame.
/// ```
public struct PipelineSkinnedModel: Sendable {
  public static let headerBytes = 64
  public static let vertexBytes = 48
  public static let maximumVertices = 1_048_575
  public static let maximumBones = 256
  public static let maximumFrames = 4_096
  public static let maximumBytes = 67_108_864

  public let bytes: Data
  public let vertexCount: Int
  public let boneCount: Int
  public let frameCount: Int
  public let framesPerSecond: Float
  public let boundsMin: SIMD3<Float>
  public let boundsMax: SIMD3<Float>
  /// SHA-256 of `bytes`, so a GPU Program restarts when the model changes.
  public let fingerprint: String

  public enum RootMotion: String, Sendable {
    /// Keeps the hips' vertical bob and sway but removes their net travel
    /// over the loop, so a walk or run cycle stays on the spot.
    case inPlace
    case keep
  }

  /// Loads an FBX file through ufbx. `animation` names an animation stack;
  /// nil or empty picks the longest one that animates anything, so an empty
  /// "Take 001" beside Mixamo's clip is skipped.
  public static func load(fbx url: URL, animation: String? = nil,
    framesPerSecond: Double = 30, rootMotion: RootMotion = .inPlace) throws -> Self {
    guard framesPerSecond.isFinite, (1...120).contains(framesPerSecond) else {
      throw PipelineEngineError.invalidInvocation(
        "Load Skinned Model frame rate must be 1–120 fps.")
    }
    var options = ufbx_load_opts()
    options.target_axes = ufbx_axes_right_handed_y_up
    options.target_unit_meters = 1
    options.space_conversion = UFBX_SPACE_CONVERSION_TRANSFORM_ROOT
    options.generate_missing_normals = true
    options.clean_skin_weights = true
    var error = ufbx_error()
    guard let scene = url.withUnsafeFileSystemRepresentation({ path in
      path.flatMap { ufbx_load_file($0, &options, &error) }
    }) else {
      throw PipelineEngineError.invalidInvocation(
        "Load Skinned Model cannot read \(url.lastPathComponent): \(describe(error)).")
    }
    defer { ufbx_free_scene(scene) }
    return try pack(scene, animation: animation, framesPerSecond: framesPerSecond,
      rootMotion: rootMotion)
  }

  // MARK: Packing

  /// One skinning matrix source: a skin cluster, or the node of a mesh that
  /// has no skin and follows its node rigidly.
  private enum Bone {
    case cluster(typedID: Int)
    case rigid(nodeTypedID: Int)
  }

  private struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: UInt32
    var joints: SIMD4<UInt8>
    var weights: SIMD4<Float>
  }

  private static func pack(_ scene: UnsafeMutablePointer<ufbx_scene>,
    animation: String?, framesPerSecond: Double, rootMotion: RootMotion) throws -> Self {
    var bones: [Bone] = []
    var vertices: [Vertex] = []
    var faceIndices = [UInt32]()
    for mesh in list(scene.pointee.meshes) {
      guard let mesh else { continue }
      let skins = list(mesh.pointee.skin_deformers)
      let skin = skins.first.flatMap { $0 }
      // Each mesh's clusters get their own bone slots: two meshes can bind
      // the same joint with different geometry_to_bone matrices.
      let firstBone = bones.count
      if let skin {
        for cluster in list(skin.pointee.clusters) {
          guard let cluster else { continue }
          bones.append(.cluster(typedID: Int(cluster.pointee.typed_id)))
        }
      } else {
        guard let node = list(mesh.pointee.instances).first.flatMap({ $0 }) else { continue }
        bones.append(.rigid(nodeTypedID: Int(node.pointee.typed_id)))
      }
      guard bones.count <= maximumBones else {
        throw PipelineEngineError.invalidInvocation(
          "Load Skinned Model supports at most \(maximumBones) bones.")
      }
      let materials = list(mesh.pointee.materials)
      let colors = materials.map { material -> UInt32 in
        guard let material else { return packColor(SIMD3(repeating: 0.8)) }
        let diffuse = material.pointee.fbx.diffuse_color
        guard diffuse.has_value else { return packColor(SIMD3(repeating: 0.8)) }
        let value = diffuse.value_vec3
        return packColor(SIMD3(Float(value.x), Float(value.y), Float(value.z)))
      }
      let positions = mesh.pointee.vertex_position
      let normals = mesh.pointee.vertex_normal
      let logical = mesh.pointee.vertex_indices
      let faceMaterials = mesh.pointee.face_material
      faceIndices = [UInt32](repeating: 0,
        count: max(1, Int(mesh.pointee.max_face_triangles) * 3))
      for (faceIndex, face) in list(mesh.pointee.faces).enumerated() {
        let triangles = faceIndices.withUnsafeMutableBufferPointer { buffer in
          ufbx_triangulate_face(buffer.baseAddress, buffer.count, mesh, face)
        }
        let material = faceIndex < faceMaterials.count
          ? Int(faceMaterials.data[faceIndex]) : 0
        let color = material < colors.count ? colors[material]
          : packColor(SIMD3(repeating: 0.8))
        for corner in 0..<Int(triangles) * 3 {
          let index = Int(faceIndices[corner])
          let position = vector(positions.values.data[Int(positions.indices.data[index])])
          let normal = normals.exists
            ? vector(normals.values.data[Int(normals.indices.data[index])])
            : SIMD3<Float>(0, 1, 0)
          var joints = SIMD4<UInt8>(repeating: 0)
          var weights = SIMD4<Float>(1, 0, 0, 0)
          joints[0] = UInt8(firstBone)
          if let skin {
            let vertex = Int(logical.data[index])
            let influence = skin.pointee.vertices.data[vertex]
            var strongest: [(bone: Int, weight: Float)] = []
            for offset in 0..<Int(influence.num_weights) {
              let weight = skin.pointee.weights.data[Int(influence.weight_begin) + offset]
              strongest.append((firstBone + Int(weight.cluster_index), Float(weight.weight)))
            }
            strongest.sort { $0.weight > $1.weight }
            let kept = strongest.prefix(4)
            let total = kept.reduce(0) { $0 + $1.weight }
            if total > 0 {
              weights = .zero
              for (slot, entry) in kept.enumerated() {
                joints[slot] = UInt8(entry.bone)
                weights[slot] = entry.weight / total
              }
            }
          }
          vertices.append(Vertex(position: position, normal: normal, color: color,
            joints: joints, weights: weights))
        }
        guard vertices.count <= maximumVertices else {
          throw PipelineEngineError.invalidInvocation(
            "Load Skinned Model supports at most \(maximumVertices / 3) triangles.")
        }
      }
    }
    guard !vertices.isEmpty, !bones.isEmpty else {
      throw PipelineEngineError.invalidInvocation("Load Skinned Model found no mesh triangles.")
    }

    let stacks = list(scene.pointee.anim_stacks).compactMap { $0 }
    let stack: UnsafeMutablePointer<ufbx_anim_stack>?
    if let animation, !animation.isEmpty {
      guard let named = stacks.first(where: { string($0.pointee.name) == animation }) else {
        throw PipelineEngineError.invalidInvocation(
          "Load Skinned Model has no animation named \(animation); it has "
            + stacks.map { string($0.pointee.name) }.joined(separator: ", ") + ".")
      }
      stack = named
    } else {
      let animated = stacks.filter { stack in
        list(stack.pointee.layers).contains { ($0?.pointee.anim_props.count ?? 0) > 0 }
      }
      stack = (animated.isEmpty ? stacks : animated).max { duration($0) < duration($1) }
    }
    let begin = stack?.pointee.time_begin ?? 0
    let seconds = stack.map(duration) ?? 0
    let frameCount = max(1, Int((seconds * framesPerSecond).rounded()))
    guard frameCount <= maximumFrames,
      headerBytes + vertices.count * vertexBytes
        + frameCount * bones.count * 64 <= maximumBytes else {
      throw PipelineEngineError.invalidInvocation(
        "Load Skinned Model animation is too long; lower its frame rate.")
    }

    // Sample one extra frame at the loop's end to measure the hips' travel.
    var matrices: [[simd_float4x4]] = []
    var hips: [SIMD3<Float>] = []
    let root = rootBone(scene)
    for frame in 0...frameCount {
      let time = begin + seconds * Double(frame) / Double(frameCount)
      var pose: UnsafeMutablePointer<ufbx_scene> = scene
      if let anim = stack?.pointee.anim {
        var evaluationError = ufbx_error()
        guard let evaluated = ufbx_evaluate_scene(scene, anim, time, nil, &evaluationError)
        else {
          throw PipelineEngineError.invalidInvocation(
            "Load Skinned Model cannot evaluate its animation: \(describe(evaluationError)).")
        }
        pose = evaluated
      }
      defer { if pose != scene { ufbx_free_scene(pose) } }
      let clusters = list(pose.pointee.skin_clusters)
      let nodes = list(pose.pointee.nodes)
      if let root, let node = nodes[root] {
        let world = node.pointee.node_to_world
        hips.append(SIMD3(Float(world.m03), Float(world.m13), Float(world.m23)))
      }
      guard frame < frameCount else { break }
      matrices.append(bones.map { bone in
        switch bone {
        case .cluster(let id):
          guard let cluster = clusters[id] else { return matrix_identity_float4x4 }
          return matrix(cluster.pointee.geometry_to_world)
        case .rigid(let id):
          guard let node = nodes[id] else { return matrix_identity_float4x4 }
          return matrix(node.pointee.geometry_to_world)
        }
      })
    }

    // Remove the loop's net horizontal travel, spread evenly over its
    // frames, so the last frame flows into the first.
    if rootMotion == .inPlace, hips.count == frameCount + 1 {
      var travel = hips[frameCount] - hips[0]
      travel.y = 0
      for frame in 0..<frameCount {
        let shift = travel * Float(frame) / Float(frameCount)
        let correction = simd_float4x4(translation: -shift)
        matrices[frame] = matrices[frame].map { correction * $0 }
      }
    }

    // Stand the first frame on y = 0, centred over the origin.
    var low = SIMD3<Float>(repeating: .infinity)
    var high = SIMD3<Float>(repeating: -.infinity)
    for vertex in vertices {
      let point = skin(vertex, matrices[0])
      low = simd_min(low, point)
      high = simd_max(high, point)
    }
    let centre = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
    let recentre = simd_float4x4(translation: -centre)
    matrices = matrices.map { frame in frame.map { recentre * $0 } }
    low -= centre
    high -= centre

    var data = Data(capacity: headerBytes + vertices.count * vertexBytes
      + frameCount * bones.count * 64)
    func append<T>(_ value: T) {
      withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
    let verticesOffset = headerBytes
    let framesOffset = verticesOffset + vertices.count * vertexBytes
    append(UInt32(vertices.count))
    append(UInt32(bones.count))
    append(UInt32(frameCount))
    append(Float(framesPerSecond))
    append(SIMD4(low, Float(seconds)))
    append(SIMD4(high, 0))
    append(UInt32(verticesOffset))
    append(UInt32(framesOffset))
    append(SIMD2<UInt32>.zero)
    for vertex in vertices {
      append(vertex.position.x); append(vertex.position.y); append(vertex.position.z)
      append(vertex.color)
      append(vertex.normal.x); append(vertex.normal.y); append(vertex.normal.z)
      append(vertex.joints)
      append(vertex.weights)
    }
    for frame in matrices {
      for bone in frame { append(bone) }
    }
    precondition(data.count == framesOffset + frameCount * bones.count * 64)
    return Self(bytes: data, vertexCount: vertices.count, boneCount: bones.count,
      frameCount: frameCount, framesPerSecond: Float(framesPerSecond),
      boundsMin: low, boundsMax: high,
      fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }

  /// The skinned bone nearest the scene root, such as a Mixamo rig's Hips.
  private static func rootBone(_ scene: UnsafeMutablePointer<ufbx_scene>) -> Int? {
    list(scene.pointee.skin_clusters).compactMap { $0?.pointee.bone_node }
      .min { $0.pointee.node_depth < $1.pointee.node_depth }
      .map { Int($0.pointee.typed_id) }
  }

  private static func skin(_ vertex: Vertex, _ bones: [simd_float4x4]) -> SIMD3<Float> {
    var result = SIMD4<Float>.zero
    for slot in 0..<4 where vertex.weights[slot] > 0 {
      result += vertex.weights[slot] * (bones[Int(vertex.joints[slot])]
        * SIMD4(vertex.position, 1))
    }
    return SIMD3(result.x, result.y, result.z)
  }

  private static func duration(_ stack: UnsafeMutablePointer<ufbx_anim_stack>) -> Double {
    max(0, stack.pointee.time_end - stack.pointee.time_begin)
  }

  private static func list<T>(_ list: some UFBXList<T>) -> UnsafeMutableBufferPointer<T> {
    UnsafeMutableBufferPointer(start: list.data, count: list.count)
  }

  private static func vector(_ value: ufbx_vec3) -> SIMD3<Float> {
    SIMD3(Float(value.x), Float(value.y), Float(value.z))
  }

  private static func matrix(_ m: ufbx_matrix) -> simd_float4x4 {
    simd_float4x4(columns: (
      SIMD4(Float(m.m00), Float(m.m10), Float(m.m20), 0),
      SIMD4(Float(m.m01), Float(m.m11), Float(m.m21), 0),
      SIMD4(Float(m.m02), Float(m.m12), Float(m.m22), 0),
      SIMD4(Float(m.m03), Float(m.m13), Float(m.m23), 1)))
  }

  private static func packColor(_ color: SIMD3<Float>) -> UInt32 {
    let clamped = simd_clamp(color, .zero, SIMD3(repeating: 1)) * 255
    return UInt32(clamped.x.rounded()) | UInt32(clamped.y.rounded()) << 8
      | UInt32(clamped.z.rounded()) << 16 | 0xFF00_0000
  }

  private static func string(_ value: ufbx_string) -> String {
    guard let data = value.data else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: data, count: value.length),
      as: UTF8.self)
  }

  private static func describe(_ error: ufbx_error) -> String {
    var error = error
    var buffer = [CChar](repeating: 0, count: 512)
    let length = ufbx_format_error(&buffer, buffer.count, &error)
    return String(decoding: buffer.prefix(length).map(UInt8.init(bitPattern:)),
      as: UTF8.self)
  }
}

/// The `{ data, count }` lists ufbx uses for every array.
protocol UFBXList<Element> {
  associatedtype Element
  var data: UnsafeMutablePointer<Element>! { get }
  var count: Int { get }
}

extension ufbx_mesh_list: UFBXList {}
extension ufbx_skin_deformer_list: UFBXList {}
extension ufbx_skin_cluster_list: UFBXList {}
extension ufbx_material_list: UFBXList {}
extension ufbx_node_list: UFBXList {}
extension ufbx_face_list: UFBXList {}
extension ufbx_anim_stack_list: UFBXList {}
extension ufbx_anim_layer_list: UFBXList {}

private extension simd_float4x4 {
  init(translation: SIMD3<Float>) {
    self = matrix_identity_float4x4
    columns.3 = SIMD4(translation, 1)
  }
}

/// Loads each FBX once per file revision and options; a Loop re-runs its
/// upstream nodes every frame.
enum PipelineSkinnedModelLoader {
  private struct Key: Hashable {
    let path: String
    let size: Int
    let modified: Date
    let animation: String
    let framesPerSecond: Double
    let rootMotion: String
  }

  private static let cache = Mutex<[(key: Key, model: PipelineSkinnedModel)]>([])

  static func model(at url: URL, animation: String, framesPerSecond: Double,
    rootMotion: PipelineSkinnedModel.RootMotion) throws -> PipelineSkinnedModel {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
      .contentModificationDateKey])
    guard values.isRegularFile == true else {
      throw PipelineEngineError.invalidInvocation(
        "Load Skinned Model needs a regular file at \(url.path).")
    }
    guard (values.fileSize ?? 0) <= 268_435_456 else {
      throw PipelineEngineError.invalidInvocation(
        "Load Skinned Model files are limited to 256 MiB.")
    }
    let key = Key(path: url.path, size: values.fileSize ?? 0,
      modified: values.contentModificationDate ?? .distantPast, animation: animation,
      framesPerSecond: framesPerSecond, rootMotion: rootMotion.rawValue)
    if let cached = cache.withLock({ $0.first { $0.key == key }?.model }) { return cached }
    let model = try PipelineSkinnedModel.load(fbx: url, animation: animation,
      framesPerSecond: framesPerSecond, rootMotion: rootMotion)
    cache.withLock { entries in
      entries.removeAll { $0.key.path == key.path }
      entries.append((key, model))
      if entries.count > 4 { entries.removeFirst() }
    }
    return model
  }

  /// A workflow names the file relative to its folder, from the home folder
  /// with `~/`, or from the filesystem root.
  static func url(for path: String, sourceMediaRoot: URL?) throws -> URL {
    guard !path.isEmpty, !path.contains("\0") else {
      throw PipelineEngineError.invalidInvocation("Load Skinned Model needs a file path.")
    }
    if path.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
    }
    if (path as NSString).isAbsolutePath {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    guard let sourceMediaRoot else {
      throw PipelineEngineError.invalidInvocation(
        "Load Skinned Model needs the workflow folder for the relative path \(path).")
    }
    return sourceMediaRoot.appendingPathComponent(path).standardizedFileURL
  }
}
