import Darwin
import Foundation
import PixeltjePipelineEngine

@main
struct PixeltjePipelineAgentMain {
  static func main() async {
    do {
      var arguments = CommandLine.arguments
      let traceURL = try PipelineTraceCLIOptions.takeDebugLog(from: &arguments)
      let configuration = try AgentConfiguration.load(arguments: arguments)
      let traceLog = try traceURL.map { try PipelineTraceLog(url: $0) }
      let server = try ACPServer(configuration: configuration, traceLog: traceLog)
      while let line = readLine(strippingNewline: true) {
        await server.handle(line)
      }
      try await server.finish()
    } catch {
      FileHandle.standardError.write(Data("Pixeltje Pipeline: \(error.localizedDescription)\n".utf8))
      exit(2)
    }
  }
}
