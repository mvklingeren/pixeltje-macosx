import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineResourceLinking

@main
enum RelinkFLUX2 {
  static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3,
      arguments.allSatisfy({ $0.hasPrefix("/") })
    else {
      fputs("Usage: pixeltje-pipeline-relink-flux2 INPUT.pixpipeline.json PACKAGE OUTPUT.pixpipeline.json\n", stderr)
      exit(2)
    }
    let input = URL(fileURLWithPath: arguments[0])
    let package = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: arguments[2])
    guard !FileManager.default.fileExists(atPath: output.path),
      input.standardizedFileURL != output.standardizedFileURL
    else {
      fputs("Output already exists or would overwrite the input.\n", stderr)
      exit(2)
    }
    let document = try PipelineJSON.decode(Data(contentsOf: input))
    let result = try PipelineCoreAIPackageRelinker.relinkNativeFluxComposite(
      in: document, toPackageAt: package)
    try PipelineJSON.encode(result.document).write(to: output, options: .atomic)
    print("Relinked \(result.linkedResourceCount) FLUX.2 resources to \(result.packageVersion)")
    print("Saved \(output.path)")
  }
}
