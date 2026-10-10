import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineTextRuntime

enum WorkflowResult: Sendable {
  case text(String)
  case image(URL)

  var summary: String {
    switch self {
    case .text(let text): text
    case .image(let url): "Image saved at \(url.path)"
    }
  }
}

actor WorkflowExecutor {
  private let engine: PixeltjePipelineEngine
  private var workflows: [String: LoadedWorkflow]
  private let outputDirectory: URL
  private let traceLog: PipelineTraceLog?
  private var callsBySession: [String: Int] = [:]

  init(engine: PixeltjePipelineEngine, configuration: LoadedAgentConfiguration,
    traceLog: PipelineTraceLog? = nil) {
    self.engine = engine
    self.traceLog = traceLog
    workflows = Dictionary(uniqueKeysWithValues: configuration.workflows.map { ($0.name, $0) })
    outputDirectory = configuration.outputDirectory
  }

  func resetBudget(for sessionID: String) {
    callsBySession[sessionID] = 0
  }

  func close(sessionID: String) {
    callsBySession.removeValue(forKey: sessionID)
  }

  func run(name: String, prompt: String, sessionID: String) async throws -> WorkflowResult {
    guard var workflow = workflows[name] else {
      throw AgentError.invalidRequest("Unknown workflow \(name).")
    }
    let count = callsBySession[sessionID, default: 0]
    guard count < 8 else {
      throw AgentError.invalidRequest("Workflow limit of eight calls reached for this turn.")
    }
    callsBySession[sessionID] = count + 1
    try Task.checkCancellation()
    if workflow.needsLink {
      workflow = LoadedWorkflow(
        name: workflow.name, description: workflow.description,
        document: try CoreAITextPipelineFamily.linkPackage(
          in: workflow.document, at: workflow.packageURL),
        packageURL: workflow.packageURL, needsLink: false)
      workflows[name] = workflow
    }
    return try await execute(
      workflow.document, packageRoot: workflow.packageURL, prompt: prompt)
  }

  func run(imageModel: LoadedAgentModel, prompt: String) async throws -> WorkflowResult {
    guard imageModel.kind == .image else {
      throw AgentError.invalidRequest("The selected model is not an image pipeline.")
    }
    let result = try await execute(
      imageModel.document, packageRoot: imageModel.packageURL, prompt: prompt)
    guard case .image = result else {
      throw AgentError.invalidRequest("The selected image model returned text.")
    }
    return result
  }

  private func execute(
    _ document: PipelineDocument, packageRoot: URL, prompt: String
  ) async throws -> WorkflowResult {
    try Task.checkCancellation()
    let invocation = PipelineInvocation(values: [
      PipelineInvocation.promptKey: .string(prompt)
    ])
    let packageIDs = Set(document.nodes.flatMap { node in
      node.resources.values.compactMap(\.linkedReference).map(\.packageID)
    })
    guard packageIDs.count <= 1 else {
      throw AgentError.invalidRequest(
        "This agent workflow needs more than one configured model package.")
    }
    let roots = Dictionary(uniqueKeysWithValues: packageIDs.map { ($0, packageRoot) })
    let output = try await engine.execute(
      document, packageRootsByID: roots, invocation: invocation,
      trace: traceLog?.handler())
    try Task.checkCancellation()
    switch output {
    case .none:
      throw AgentError.invalidRequest("This workflow completed without an outcome.")
    case .text(let generated): return .text(generated.text)
    case .plainText(let generated): return .text(generated.text)
    case .video, .videoFrame:
      throw AgentError.invalidRequest("This agent does not return video workflows.")
    case .audio:
      throw AgentError.invalidRequest("This agent does not return audio workflows.")
    case .model:
      throw AgentError.invalidRequest("This agent does not run model-training workflows.")
    case .image(let generated):
      let url = outputDirectory.appendingPathComponent("\(UUID().uuidString).png")
      try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
      try Self.writePNG(generated, to: url)
      return .image(url)
    }
  }

  private static func writePNG(_ output: PipelineGeneratedImage, to url: URL) throws {
    let count = output.width.multipliedReportingOverflow(by: output.height)
    guard !count.overflow, count.partialValue > 0,
      count.partialValue <= Int.max / 4,
      output.planarRGB.count == count.partialValue * 3,
      output.alpha.map({ $0.count == count.partialValue && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) ?? true
    else { throw AgentError.invalidRequest("Generated image has invalid dimensions.") }
    var pixels = [UInt8](repeating: 255, count: count.partialValue * 4)
    for index in 0..<count.partialValue {
      pixels[index * 4 + 3] = UInt8(((output.alpha?[index] ?? 1) * 255).rounded())
      for channel in 0..<3 {
        let component = output.planarRGB[channel * count.partialValue + index]
        guard component.isFinite else {
          throw AgentError.invalidRequest("Generated image contains non-finite pixels.")
        }
        let value = min(max(output.encoding.normalizedSRGBComponent(from: component), 0), 1)
        pixels[index * 4 + channel] = UInt8((value * 255).rounded())
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: output.width, height: output.height,
        bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: output.width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { throw AgentError.invalidRequest("Could not encode generated image.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw AgentError.invalidRequest("Could not write generated image.")
    }
  }
}
