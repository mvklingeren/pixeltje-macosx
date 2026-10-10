import Foundation
import PixeltjeModelDesign
import PixeltjePipelineDomain

let arguments = Array(CommandLine.arguments.dropFirst())
do {
  if arguments.count == 2 && arguments[0] == "--starter" {
    let destination = URL(fileURLWithPath: arguments[1])
    try PipelineJSON.encode(ModelWorkflowBridge.importLegacy(.starter()))
      .write(to: destination, options: .atomic)
    print(destination.path)
    exit(0)
  }
  if arguments.count == 2 && arguments[0] == "--starter-mnist" {
    let destination = URL(fileURLWithPath: arguments[1])
    try PipelineJSON.encode(ModelWorkflowBridge.importLegacy(.mnistStarter()))
      .write(to: destination, options: .atomic)
    print(destination.path)
    exit(0)
  }
  if arguments.count == 3 && arguments[0] == "--migrate-legacy" {
    let source = URL(fileURLWithPath: arguments[1])
    let destination = URL(fileURLWithPath: arguments[2])
    let legacy = try ModelDesignJSON.decode(Data(contentsOf: source))
    try PipelineJSON.encode(ModelWorkflowBridge.importLegacy(legacy))
      .write(to: destination, options: .atomic)
    print(destination.path)
    exit(0)
  }
  guard arguments.count == 2 else {
    fputs("usage: pixeltje-model-export [--starter OUTPUT.pixpipeline.json | --starter-mnist OUTPUT.pixpipeline.json | --migrate-legacy INPUT.pixmodel.json OUTPUT.pixpipeline.json | INPUT.pixpipeline.json OUTPUT_DIRECTORY]\n", stderr)
    exit(2)
  }
  let source = URL(fileURLWithPath: arguments[0])
  let destination = URL(fileURLWithPath: arguments[1])
  let document = try PipelineJSON.decode(Data(contentsOf: source))
  try ModelPythonExporter.export(
    ModelWorkflowBridge.design(in: document), workflow: document, to: destination)
  print(destination.path)
} catch {
  fputs("pixeltje-model-export: \(error.localizedDescription)\n", stderr)
  exit(1)
}
