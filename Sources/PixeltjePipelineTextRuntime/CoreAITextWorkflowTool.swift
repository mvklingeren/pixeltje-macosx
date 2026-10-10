import Foundation
import FoundationModels

@Generable
public struct CoreAITextWorkflowArguments {
  @Guide(description: "The exact name of a configured pipeline workflow")
  public var workflow: String

  @Guide(description: "The prompt to give that workflow")
  public var prompt: String
}

/// One reviewed tool surface for the agent. The host decides which named
/// workflows are available; generated text cannot supply a file path or code.
public struct CoreAITextWorkflowTool: Tool {
  public let name = "run_pipeline"
  public let description: String
  private let execute: @Sendable (String, String) async throws -> String

  public init(
    workflows: [String: String],
    execute: @escaping @Sendable (String, String) async throws -> String
  ) {
    description = "Run one configured Pixeltje Pipeline workflow. Available workflows: "
      + workflows.keys.sorted().map { "\($0): \(workflows[$0] ?? "")" }
        .joined(separator: "; ") + "."
    self.execute = execute
  }

  public func call(arguments: CoreAITextWorkflowArguments) async throws -> String {
    try await execute(arguments.workflow, arguments.prompt)
  }
}
