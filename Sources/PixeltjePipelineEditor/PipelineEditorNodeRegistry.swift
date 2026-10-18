import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineFLUX2Runtime
import PixeltjePipelineSDXSRuntime
import PixeltjePipelineStableAudioRuntime
import PixeltjePipelineTextRuntime
import PixeltjePipelineSegmentationRuntime

extension PipelineNodeRegistry {
  static let pipelineEditor: PipelineNodeRegistry = {
    var registry = PipelineNodeRegistry.coreAIV1
    registry.register(ZImageCompositeNode.descriptor())
    registry.register(FLUX2KleinPipelineFamily.makeCompositeNodeDescriptor())
    registry.register(FLUX2Klein9BSplitFamily.descriptor())
    registry.register(SDXSPipelineFamily.descriptor())
    registry.register(StableAudio3Family.descriptor())
    registry.register(CoreAITextPipelineFamily.makeCompositeNodeDescriptor())
    registry.register(SAM31PipelineFamily.descriptor())
    for descriptor in registry.allDescriptors where descriptor.isTerminal {
      var visible = descriptor
      visible.outputs.append(.init(name: PipelineControlPorts.completed, type: .control))
      registry.register(visible)
    }
    return registry
  }()
}
