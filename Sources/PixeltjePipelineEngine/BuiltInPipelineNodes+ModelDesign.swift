import PixeltjeModelDesign
import PixeltjePipelineDomain

extension PipelineNodeRegistry {
  static var modelDesignDescriptors: [PipelineNodeDescriptor] {
    [
      .init(kind: .modelInput, displayName: "Model Input", category: "Model Design",
        outputs: [.init(name: "tensor", type: .modelTensor)],
        parameters: [
          .init(name: "name", valueType: .string, defaultValue: .string("image")),
          .init(name: "channels", valueType: .integer, defaultValue: .integer(3)),
          .init(name: "height", valueType: .integer, defaultValue: .integer(64)),
          .init(name: "width", valueType: .integer, defaultValue: .integer(64)),
          .init(name: "dtype", valueType: .string, defaultValue: .string("float32")),
        ]),
      .init(kind: .modelLayer, displayName: "Model Layer", category: "Model Design",
        inputs: [.init(name: "input", type: .modelTensor)],
        outputs: [.init(name: "tensor", type: .modelTensor)],
        parameters: [
          .init(name: "name", valueType: .string, defaultValue: .string("Layer")),
          .init(name: "operation", valueType: .string, defaultValue: .string("conv2d")),
          .init(name: "units", valueType: .integer, defaultValue: .integer(16)),
          .init(name: "kernelSize", valueType: .integer, defaultValue: .integer(3)),
        ]),
      .init(kind: .modelMerge, displayName: "Model Merge", category: "Model Design",
        inputs: [.init(name: "left", type: .modelTensor),
          .init(name: "right", type: .modelTensor)],
        outputs: [.init(name: "tensor", type: .modelTensor)],
        parameters: [
          .init(name: "name", valueType: .string, defaultValue: .string("Merge")),
          .init(name: "operation", valueType: .string, defaultValue: .string("add")),
          .init(name: "axis", valueType: .integer, defaultValue: .integer(0)),
        ]),
      .init(kind: .modelOutput, displayName: "Model Output", category: "Model Design",
        inputs: [.init(name: "input", type: .modelTensor)],
        outputs: [.init(name: "model", type: .modelDefinition)],
        parameters: [.init(name: "name", valueType: .string,
          defaultValue: .string("output"))]),
      .init(kind: .modelTrain, displayName: "Train Model", category: "Model Design",
        inputs: [.init(name: "model", type: .modelDefinition),
          .init(name: "dataset", type: .string, isRequired: false)],
        parameters: [
          .init(name: "task", valueType: .string,
            defaultValue: .string("pairedImages")),
          .init(name: "datasetPreset", valueType: .string,
            defaultValue: .string("none")),
          .init(name: "epochs", valueType: .integer, defaultValue: .integer(10)),
          .init(name: "batchSize", valueType: .integer, defaultValue: .integer(8)),
          .init(name: "learningRate", valueType: .number,
            defaultValue: .number(0.001)),
          .init(name: "seed", valueType: .integer, defaultValue: .integer(42)),
        ], isTerminal: true),
    ]
  }
}
