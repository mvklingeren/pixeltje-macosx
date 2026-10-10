import PixeltjeModelDesign
import PixeltjePipelineDomain

enum PipelineModelDesignNodes {
  static let executors: [PipelineNodeExecutor] = [
    PipelineNodeExecutor(kind: .modelInput) { node, _, _ in
      PipelineNodeResult(outputs: ["tensor": .init(node.id, type: .modelTensor)])
    },
    PipelineNodeExecutor(kind: .modelLayer) { node, inputs, _ in
      guard inputs["input"]?.value(as: PipelineNodeID.self) != nil else {
        throw PipelineEngineError.planningFailed("Model Layer needs a tensor input.")
      }
      return PipelineNodeResult(outputs: ["tensor": .init(node.id, type: .modelTensor)])
    },
    PipelineNodeExecutor(kind: .modelMerge) { node, inputs, _ in
      guard inputs["left"]?.value(as: PipelineNodeID.self) != nil,
        inputs["right"]?.value(as: PipelineNodeID.self) != nil else {
        throw PipelineEngineError.planningFailed("Model Merge needs both tensor inputs.")
      }
      return PipelineNodeResult(outputs: ["tensor": .init(node.id, type: .modelTensor)])
    },
    PipelineNodeExecutor(kind: .modelOutput) { node, inputs, _ in
      guard inputs["input"]?.value(as: PipelineNodeID.self) != nil else {
        throw PipelineEngineError.planningFailed("Model Output needs a tensor input.")
      }
      return PipelineNodeResult(outputs: ["model": .init(node.id, type: .modelDefinition)])
    },
  ]
}
