import Foundation
import PixeltjePipelineDomain
import PixeltjePipelineTextRuntime

struct AgentConfiguration: Decodable {
  struct Model: Decodable {
    let id: String
    let name: String
    let package: String
    let pipeline: String?
  }

  struct Workflow: Decodable {
    let name: String
    let description: String
    let pipeline: String
    let package: String
  }

  struct ImageModel: Decodable {
    let id: String
    let name: String
    let pipeline: String
    let package: String
  }

  var agentPipeline: String?
  var agentPackage: String?
  var defaultModel: String?
  var models: [Model]?
  var systemPrompt: String?
  var maximumResponseTokens: Int?
  var temperature: Double?
  var topK: Int?
  var outputDirectory: String?
  var sessionDirectory: String?
  var modelWorkflowCalls: Bool?
  var imageModels: [ImageModel]?
  var workflows: [Workflow]?

  static func load(arguments: [String]) throws -> LoadedAgentConfiguration {
    let configurationURL: URL?
    if arguments.count == 1 {
      configurationURL = nil
    } else if arguments.count == 3 && arguments[1] == "--config" {
      configurationURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    } else {
      throw AgentError.configuration(
        "Usage: pixeltje-pipeline-agent [--config /absolute/path/agent.json] [--debug-log FILE]")
    }
    let config = try configurationURL.map {
      try JSONDecoder().decode(Self.self, from: Data(contentsOf: $0))
    } ?? Self()
    let base = configurationURL?.deletingLastPathComponent()
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    func resolve(_ path: String) -> URL {
      let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
      return url
    }
    let configuredPackageURL = config.agentPackage.map(resolve)
      ?? CoreAITextPipelineFamily.defaultPackageURL()
    let library = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pixeltje/models", isDirectory: true)
    let gemmaURL = library.appendingPathComponent(
      "gemma-3-12b-instruct-coreai", isDirectory: true)
    let packageURL: URL = if config.agentPackage == nil && config.agentPipeline == nil
      && !FileManager.default.fileExists(
        atPath: configuredPackageURL.appendingPathComponent("metadata.json").path)
      && FileManager.default.fileExists(
        atPath: gemmaURL.appendingPathComponent("metadata.json").path)
    { gemmaURL } else { configuredPackageURL }
    func model(id: String, name: String, package: URL, pipeline: String?) throws
      -> LoadedAgentModel
    {
      guard !id.isEmpty, !name.isEmpty else {
        throw AgentError.configuration("Model IDs and names must be nonempty.")
      }
      let document = try pipeline.map {
        try PipelineJSON.decode(Data(contentsOf: resolve($0)))
      } ?? CoreAITextPipelineFamily.makeNativeTextCompletionDocument()
      return LoadedAgentModel(
        id: id, name: name, document: document, packageURL: package,
        needsLink: pipeline == nil, kind: .text)
    }
    func knownName(for url: URL) -> String {
      switch url.lastPathComponent {
      case "qwen3-coreai": "Qwen 3 0.6B"
      case "gemma-3-12b-instruct-coreai": "Gemma 3 12B Instruct"
      default: url.lastPathComponent
      }
    }
    var models: [LoadedAgentModel]
    if let configured = config.models {
      models = try configured.map {
        try model(id: $0.id, name: $0.name, package: resolve($0.package),
          pipeline: $0.pipeline)
      }
    } else {
      var discovered = [try model(
        id: packageURL.lastPathComponent, name: knownName(for: packageURL),
        package: packageURL, pipeline: config.agentPipeline)]
      for folder in ["qwen3-coreai", "gemma-3-12b-instruct-coreai"] {
        let candidate = library.appendingPathComponent(folder, isDirectory: true)
        guard candidate.standardizedFileURL != packageURL.standardizedFileURL,
          FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("metadata.json").path)
        else { continue }
        discovered.append(try model(
          id: folder, name: knownName(for: candidate), package: candidate, pipeline: nil))
      }
      models = discovered
    }
    for image in config.imageModels ?? [] {
      guard !image.id.isEmpty, !image.name.isEmpty else {
        throw AgentError.configuration("Image model IDs and names must be nonempty.")
      }
      let document = try PipelineJSON.decode(Data(contentsOf: resolve(image.pipeline)))
      guard document.mode == .textToImage else {
        throw AgentError.configuration("Image model \(image.id) must use a text-to-image pipeline.")
      }
      models.append(LoadedAgentModel(
        id: image.id, name: image.name, document: document,
        packageURL: resolve(image.package), needsLink: false, kind: .image))
    }
    guard !models.isEmpty else {
      throw AgentError.configuration("Configure at least one text or image model.")
    }
    guard Set(models.map(\.id)).count == models.count else {
      throw AgentError.configuration("Model IDs must be unique.")
    }
    let defaultModelID = config.defaultModel ?? models[0].id
    guard models.contains(where: { $0.id == defaultModelID }) else {
      throw AgentError.configuration("The default model must be in the model list.")
    }
    let workflows = try (config.workflows ?? []).map { item -> LoadedWorkflow in
      guard !item.name.isEmpty, !item.name.contains(where: \.isWhitespace) else {
        throw AgentError.configuration("Workflow names must be nonempty single words.")
      }
      let workflowPackage = resolve(item.package)
      let builtInText = item.pipeline == "builtin:text"
      let workflowDocument: PipelineDocument
      if builtInText {
        workflowDocument = CoreAITextPipelineFamily.makeNativeTextCompletionDocument()
      } else {
        workflowDocument = try PipelineJSON.decode(Data(contentsOf: resolve(item.pipeline)))
      }
      return LoadedWorkflow(
        name: item.name, description: item.description,
        document: workflowDocument, packageURL: workflowPackage,
        needsLink: builtInText)
    }
    guard Set(workflows.map(\.name)).count == workflows.count else {
      throw AgentError.configuration("Workflow names must be unique.")
    }
    let settings = CoreAITextGenerationInvocation(
      prompt: "", systemPrompt: config.systemPrompt ?? "You are Pixeltje Pipeline, a helpful AI assistant. Use run_pipeline when a configured workflow can help answer the user.",
      maximumResponseTokens: config.maximumResponseTokens ?? 1024,
      temperature: config.temperature ?? 0.7,
      topK: config.topK ?? 40)
    let outputDirectory = config.outputDirectory.map(resolve)
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pixeltje Pipeline/Outputs", isDirectory: true)
    let sessionDirectory = config.sessionDirectory.map(resolve)
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pixeltje/pipeline-agent/sessions", isDirectory: true)
    return LoadedAgentConfiguration(
      models: models, defaultModelID: defaultModelID, settings: settings,
      workflows: workflows,
      modelWorkflowCalls: config.modelWorkflowCalls ?? true,
      outputDirectory: outputDirectory, sessionDirectory: sessionDirectory)
  }
}

struct LoadedAgentModel: Sendable {
  enum Kind: Sendable { case text, image }
  let id: String
  let name: String
  let document: PipelineDocument
  let packageURL: URL
  let needsLink: Bool
  let kind: Kind
}

struct LoadedWorkflow: Sendable {
  let name: String
  let description: String
  let document: PipelineDocument
  let packageURL: URL
  let needsLink: Bool
}

struct LoadedAgentConfiguration: Sendable {
  let models: [LoadedAgentModel]
  let defaultModelID: String
  let settings: CoreAITextGenerationInvocation
  let workflows: [LoadedWorkflow]
  let modelWorkflowCalls: Bool
  let outputDirectory: URL
  let sessionDirectory: URL
}

enum AgentError: LocalizedError {
  case configuration(String)
  case invalidRequest(String)

  var errorDescription: String? {
    switch self {
    case .configuration(let message), .invalidRequest(let message): message
    }
  }
}
