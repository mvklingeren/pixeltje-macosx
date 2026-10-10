import Foundation
import PixeltjePipelineDomain
import simd

/// Column-major matrix with column-vector multiplication. Runtime data only;
/// saved workflows retain the numeric parameters that produce the matrix.
public struct PipelineMatrix4x4: Sendable, PipelineTraceRepresentable {
  public let value: simd_float4x4

  public init(_ value: simd_float4x4) throws {
    guard (0..<4).allSatisfy({ column in
      (0..<4).allSatisfy { value[column][$0].isFinite }
    }) else { throw PipelineEngineError.invalidInvocation("Matrix components must be finite.") }
    self.value = value
  }

  public func pipelineTraceValue() -> PipelineTraceValue {
    .init(type: "matrix4x4", summary: (0..<4).map { row in
      (0..<4).map { String(value[$0][row]) }.joined(separator: ", ")
    }.joined(separator: "\n"))
  }
}

/// Validated indexed triangle geometry. Positions use a right-handed space
/// with +Y up. Counterclockwise triangles define outward-facing normals.
public struct PipelineMesh3D: Sendable, PipelineTraceRepresentable {
  public let positions: [SIMD3<Float>]
  public let normals: [SIMD3<Float>]
  public let textureCoordinates: [SIMD2<Float>]?
  public let indices: [UInt32]

  public func pipelineTraceValue() -> PipelineTraceValue {
    .init(type: "mesh3D", summary: "Mesh: \(positions.count) vertices, \(indices.count / 3) triangles")
  }

  public static func decode(_ text: String, normalMode: String = "flat") throws -> Self {
    struct Description: Decodable {
      var vertices: [[Float]]
      var triangles: [[UInt32]]
      var normals: [[Float]]?
      var textureCoordinates: [[Float]]?
    }
    guard ["flat", "smooth"].contains(normalMode) else {
      throw PipelineEngineError.invalidInvocation("Mesh normalMode must be flat or smooth.")
    }
    let data = Data(text.utf8)
    guard data.count <= 16 * 1024 * 1024 else {
      throw PipelineEngineError.invalidInvocation("Mesh JSON exceeds 16 MiB.")
    }
    let source: Description
    do { source = try JSONDecoder().decode(Description.self, from: data) }
    catch {
      throw PipelineEngineError.invalidInvocation(
        "Mesh needs JSON vertices (XYZ triples) and triangles (zero-based index triples): \(error.localizedDescription)")
    }
    guard (3...100_000).contains(source.vertices.count),
      (1...200_000).contains(source.triangles.count) else {
      throw PipelineEngineError.invalidInvocation("Mesh supports 3–100,000 vertices and 1–200,000 triangles.")
    }
    func vector(_ values: [Float]) throws -> SIMD3<Float> {
      guard values.count == 3,
        values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
        throw PipelineEngineError.invalidInvocation("Mesh vectors need three finite components within ±1,000,000.")
      }
      return SIMD3(values[0], values[1], values[2])
    }
    let positions = try source.vertices.map(vector)
    var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
    var faceNormals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    for (index, triangle) in source.triangles.enumerated() {
      if index.isMultiple(of: 1024) { try Task.checkCancellation() }
      guard triangle.count == 3, triangle.allSatisfy({ Int($0) < positions.count }) else {
        throw PipelineEngineError.invalidInvocation("Triangle \(index) needs three valid vertex indices.")
      }
      let a = positions[Int(triangle[0])]
      let b = positions[Int(triangle[1])]
      let c = positions[Int(triangle[2])]
      let normal = simd_cross(b - a, c - a)
      guard simd_length_squared(normal).isFinite, simd_length_squared(normal) > 1e-20 else {
        throw PipelineEngineError.invalidInvocation("Triangle \(index) is degenerate.")
      }
      faceNormals.append(simd_normalize(normal))
      for vertex in triangle { normals[Int(vertex)] += normal }
      indices.append(contentsOf: triangle)
    }
    let uv: [SIMD2<Float>]?
    if let supplied = source.textureCoordinates {
      guard supplied.count == positions.count,
        supplied.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
        throw PipelineEngineError.invalidInvocation("Texture coordinates need one finite UV pair per vertex.")
      }
      uv = supplied.map { SIMD2($0[0], $0[1]) }
    } else { uv = nil }
    if let supplied = source.normals {
      guard supplied.count == positions.count else {
        throw PipelineEngineError.invalidInvocation("Supply one normal per vertex.")
      }
      normals = try supplied.map(vector)
    } else if normalMode == "flat" {
      // Split shared corners so each face retains its own lighting normal.
      return Self(
        positions: indices.map { positions[Int($0)] },
        normals: indices.indices.map { faceNormals[$0 / 3] },
        textureCoordinates: uv.map { values in indices.map { values[Int($0)] } },
        indices: indices.indices.map { UInt32($0) })
    }
    for index in normals.indices {
      guard simd_length_squared(normals[index]).isFinite,
        simd_length_squared(normals[index]) > 1e-20 else {
        throw PipelineEngineError.invalidInvocation("Vertex \(index) has no usable normal; remove unused vertices or supply normals.")
      }
      normals[index] = simd_normalize(normals[index])
    }
    return Self(positions: positions, normals: normals, textureCoordinates: uv, indices: indices)
  }
}

/// Shared reader for scalar inputs and their saved parameter fallbacks.
struct PipelineGeometryParameters {
  let node: PipelineNode
  var inputs: [String: PipelineNodeValue] = [:]

  func number(_ name: String, default fallback: Double) throws -> Float {
    let result: Double
    if let input = inputs[name] {
      guard let value = input.value(as: Double.self) else {
        throw PipelineEngineError.invalidInvocation("\(node.id.rawValue).\(name) needs a number.")
      }
      result = value
    } else if let saved = node.parameters[name] {
      guard let value = saved.numberValue else {
        throw PipelineEngineError.invalidInvocation("\(node.id.rawValue).\(name) needs a number.")
      }
      result = value
    } else { result = fallback }
    guard result.isFinite, Float(result).isFinite else {
      throw PipelineEngineError.invalidInvocation("\(node.id.rawValue).\(name) must be a finite float.")
    }
    return Float(result)
  }

  func dimension(_ name: String) throws -> Int {
    let value: Int64
    if let input = inputs[name] {
      if let number = input.value(as: Int.self) { value = Int64(number) }
      else if let number = input.value(as: Int64.self) { value = number }
      else { throw PipelineEngineError.invalidInvocation("\(name) needs an integer.") }
    } else if let saved = node.parameters[name] {
      guard let number = saved.integerValue else {
        throw PipelineEngineError.invalidInvocation("\(name) needs an integer.")
      }
      value = number
    } else { value = 512 }
    guard value > 0, let exact = Int(exactly: value) else {
      throw PipelineEngineError.invalidInvocation("3D render dimensions must be positive integers.")
    }
    return exact
  }

  func string(_ name: String, default fallback: String) throws -> String {
    guard let saved = node.parameters[name] else { return fallback }
    guard let result = saved.stringValue else {
      throw PipelineEngineError.invalidInvocation("\(name) needs text.")
    }
    return result
  }

  func vector(_ prefix: String, default fallback: SIMD3<Float>) throws -> SIMD3<Float> {
    try SIMD3(number(prefix + "X", default: Double(fallback.x)),
      number(prefix + "Y", default: Double(fallback.y)),
      number(prefix + "Z", default: Double(fallback.z)))
  }
}

enum PipelineGeometryNodes {
  static let executors: [PipelineNodeExecutor] = [
    .init(kind: .meshFromVertices) { node, inputs, _ in
      guard let data = inputs["data"]?.value(as: String.self) else {
        throw PipelineEngineError.invalidInvocation("Mesh from Vertices needs JSON text on data.")
      }
      let mode = try PipelineGeometryParameters(node: node).string("normalMode", default: "flat")
      return PipelineNodeResult(outputs: [
        "mesh": PipelineNodeValue(try PipelineMesh3D.decode(data, normalMode: mode), type: .mesh3D)
      ])
    },
    .init(kind: .transformMatrix) { node, inputs, _ in
      let matrix = try transform(PipelineGeometryParameters(node: node, inputs: inputs))
      return PipelineNodeResult(outputs: ["matrix": PipelineNodeValue(matrix, type: .matrix4x4)])
    },
    .init(kind: .cameraMatrices) { node, inputs, _ in
      let matrices = try camera(PipelineGeometryParameters(node: node, inputs: inputs))
      return PipelineNodeResult(outputs: [
        "viewMatrix": PipelineNodeValue(matrices.view, type: .matrix4x4),
        "projectionMatrix": PipelineNodeValue(matrices.projection, type: .matrix4x4),
      ])
    },
  ]

  static func transform(_ parameters: PipelineGeometryParameters) throws -> PipelineMatrix4x4 {
    let translation = try parameters.vector("translation", default: .zero)
    let rotation = try parameters.vector("rotation", default: .zero)
    let scale = try parameters.vector("scale", default: SIMD3(repeating: 1))
    guard scale.x != 0, scale.y != 0, scale.z != 0 else {
      throw PipelineEngineError.invalidInvocation("Transform scale must be nonzero on every axis.")
    }
    func angle(_ value: Float) -> Float {
      value.truncatingRemainder(dividingBy: 360) * .pi / 180
    }
    var t = matrix_identity_float4x4
    t.columns.3 = SIMD4(translation, 1)
    let s = simd_float4x4(diagonal: SIMD4(scale, 1))
    let x = simd_float4x4(simd_quatf(angle: angle(rotation.x), axis: SIMD3(1, 0, 0)))
    let y = simd_float4x4(simd_quatf(angle: angle(rotation.y), axis: SIMD3(0, 1, 0)))
    let z = simd_float4x4(simd_quatf(angle: angle(rotation.z), axis: SIMD3(0, 0, 1)))
    return try PipelineMatrix4x4(t * z * y * x * s)
  }

  static func camera(_ parameters: PipelineGeometryParameters) throws
    -> (view: PipelineMatrix4x4, projection: PipelineMatrix4x4) {
    let eye = try parameters.vector("position", default: SIMD3(0, 0, 4))
    let target = try parameters.vector("target", default: .zero)
    let up = try parameters.vector("up", default: SIMD3(0, 1, 0))
    guard simd_length_squared(eye - target).isFinite,
      simd_length_squared(eye - target) > 1e-12,
      simd_length_squared(up).isFinite, simd_length_squared(up) > 1e-12 else {
      throw PipelineEngineError.invalidInvocation("Camera position and target must differ, and up must be nonzero.")
    }
    let backward = simd_normalize(eye - target)
    let side = simd_cross(simd_normalize(up), backward)
    guard simd_length_squared(side) > 1e-12 else {
      throw PipelineEngineError.invalidInvocation("Camera up must not be parallel to its viewing direction.")
    }
    let right = simd_normalize(side)
    let vertical = simd_cross(backward, right)
    let view = simd_float4x4(columns: (
      SIMD4(right.x, vertical.x, backward.x, 0),
      SIMD4(right.y, vertical.y, backward.y, 0),
      SIMD4(right.z, vertical.z, backward.z, 0),
      SIMD4(-simd_dot(right, eye), -simd_dot(vertical, eye), -simd_dot(backward, eye), 1)))
    let near = try parameters.number("nearClip", default: 0.1)
    let far = try parameters.number("farClip", default: 100)
    guard near > 0, far > near else {
      throw PipelineEngineError.invalidInvocation("Camera clipping needs 0 < nearClip < farClip.")
    }
    let aspect = Float(try parameters.dimension("width")) / Float(try parameters.dimension("height"))
    let projection: simd_float4x4
    switch try parameters.string("projection", default: "perspective") {
    case "perspective":
      let fov = try parameters.number("fieldOfView", default: 45)
      guard fov > 0, fov < 179 else {
        throw PipelineEngineError.invalidInvocation("Camera fieldOfView must be between 0 and 179 degrees.")
      }
      let y = 1 / tan(fov * .pi / 360)
      let z = far / (near - far)
      projection = simd_float4x4(columns: (
        SIMD4(y / aspect, 0, 0, 0), SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    case "orthographic":
      let height = try parameters.number("orthographicHeight", default: 2)
      guard height > 0 else {
        throw PipelineEngineError.invalidInvocation("Camera orthographicHeight must be positive.")
      }
      projection = simd_float4x4(columns: (
        SIMD4(2 / (height * aspect), 0, 0, 0), SIMD4(0, 2 / height, 0, 0),
        SIMD4(0, 0, 1 / (near - far), 0), SIMD4(0, 0, near / (near - far), 1)))
    default:
      throw PipelineEngineError.invalidInvocation("Camera projection must be perspective or orthographic.")
    }
    // Right-handed camera looking down -Z; Metal clip depth is 0…1.
    return (try PipelineMatrix4x4(view), try PipelineMatrix4x4(projection))
  }
}
