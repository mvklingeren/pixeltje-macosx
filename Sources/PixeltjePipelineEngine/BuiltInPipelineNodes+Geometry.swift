import PixeltjePipelineDomain

extension PipelineNodeKind {
  public static let meshFromVertices = PipelineNodeKind(rawValue: "geometry.meshFromVertices")
  public static let transformMatrix = PipelineNodeKind(rawValue: "math.transformMatrix")
  public static let cameraMatrices = PipelineNodeKind(rawValue: "camera.matrices")
  public static let renderMetal = PipelineNodeKind(rawValue: "render.metal")
  public static let gpuProgram = PipelineNodeKind(rawValue: "gpu.program")
}

extension PipelineNodeRegistry {
  static var geometryDescriptors: [PipelineNodeDescriptor] {
    func numericPorts(_ names: [String]) -> [PipelinePortDescriptor] {
      names.map { .init(name: $0, type: .number, isRequired: false) }
    }
    func numericParameters(_ values: [(String, Double)]) -> [PipelineParameterDescriptor] {
      values.map { .init(name: $0.0, valueType: .number, defaultValue: .number($0.1)) }
    }
    let dimensions: [PipelinePortDescriptor] = [
      .init(name: "width", type: .integer, isRequired: false),
      .init(name: "height", type: .integer, isRequired: false),
    ]
    let sizeParameters: [PipelineParameterDescriptor] = [
      .init(name: "width", valueType: .integer, defaultValue: .integer(512)),
      .init(name: "height", valueType: .integer, defaultValue: .integer(512)),
    ]
    let transform: [(String, Double)] = [
      ("translationX", 0), ("translationY", 0), ("translationZ", 0),
      ("rotationX", 0), ("rotationY", 0), ("rotationZ", 0),
      ("scaleX", 1), ("scaleY", 1), ("scaleZ", 1),
    ]
    let camera: [(String, Double)] = [
      ("positionX", 0), ("positionY", 0), ("positionZ", 4),
      ("targetX", 0), ("targetY", 0), ("targetZ", 0),
      ("upX", 0), ("upY", 1), ("upZ", 0),
      ("fieldOfView", 45), ("nearClip", 0.1), ("farClip", 100),
      ("orthographicHeight", 2),
    ]
    return [
      .init(kind: .meshFromVertices, displayName: "Mesh from Vertices", category: "Geometry",
        inputs: [.init(name: "data", type: .string)],
        outputs: [.init(name: "mesh", type: .mesh3D)],
        parameters: [
          .init(name: "normalMode", valueType: .string, defaultValue: .string("flat"))
        ]),
      .init(kind: .transformMatrix, displayName: "Transform Matrix", category: "Geometry",
        inputs: numericPorts(transform.map(\.0)),
        outputs: [.init(name: "matrix", type: .matrix4x4)],
        parameters: numericParameters(transform)),
      .init(kind: .cameraMatrices, displayName: "Camera Matrices", category: "Geometry",
        inputs: numericPorts(camera.map(\.0)) + dimensions,
        outputs: [
          .init(name: "viewMatrix", type: .matrix4x4),
          .init(name: "projectionMatrix", type: .matrix4x4),
        ],
        parameters: numericParameters(camera) + sizeParameters + [
          .init(name: "projection", valueType: .string, defaultValue: .string("perspective"))
        ]),
      .init(kind: .renderMetal, displayName: "Metal Render", category: "Geometry",
        inputs: [
          .init(name: "state", type: .string, isRequired: false),
          .init(name: "source", type: .string, isRequired: false),
          .init(name: "sourceFile", type: .string, isRequired: false),
          .init(name: "mesh", type: .mesh3D, isRequired: false),
          .init(name: "worldMatrix", type: .matrix4x4, isRequired: false),
          .init(name: "viewMatrix", type: .matrix4x4, isRequired: false),
          .init(name: "projectionMatrix", type: .matrix4x4, isRequired: false),
        ] + dimensions,
        outputs: [.init(name: "image", type: .image), .init(name: "mask", type: .mask)],
        parameters: sizeParameters + numericParameters([
          ("lightX", 0.5), ("lightY", 0.8), ("lightZ", 1),
          ("lightIntensity", 0.8), ("ambient", 0.2),
        ]) + [
          .init(name: "color", valueType: .string, defaultValue: .string("#F28C28")),
          .init(name: "backgroundColor", valueType: .string, defaultValue: .string("#00000000")),
          .init(name: "mode", valueType: .string, defaultValue: .string("filled")),
        ]),
      .init(kind: .gpuProgram, displayName: "GPU Program", category: "Geometry",
        inputs: [
          .init(name: "program", type: .string),
          .init(name: "source", type: .string, isRequired: false),
          .init(name: "sourceFile", type: .string, isRequired: false),
          .init(name: "parameters", type: .string, isRequired: false),
          .init(name: "pointerX", type: .number, isRequired: false),
          .init(name: "pointerY", type: .number, isRequired: false),
          .init(name: "actionCount", type: .number, isRequired: false),
          .init(name: "secondaryActionCount", type: .number, isRequired: false),
          .init(name: "moveX", type: .number, isRequired: false),
          .init(name: "moveY", type: .number, isRequired: false),
          .init(name: "keys", type: .number, isRequired: false),
          .init(name: "assets", type: .assetBundle, isRequired: false),
          .init(name: "seed", type: .seed, isRequired: false),
          .init(name: "framesPerSecond", type: .number, isRequired: false),
        ] + dimensions,
        outputs: [
          .init(name: "image", type: .image),
          .init(name: "sceneRequest", type: .integer),
        ],
        parameters: sizeParameters + [
          .init(name: "framesPerSecond", valueType: .number, defaultValue: .number(60)),
          .init(name: "seed", valueType: .integer, defaultValue: .integer(1)),
        ]),
    ]
  }
}
