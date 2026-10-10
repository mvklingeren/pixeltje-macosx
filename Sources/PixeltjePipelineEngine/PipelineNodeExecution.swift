import Foundation
import PixeltjePipelineDomain

/// A transient value on one graph edge. Only compiled node implementations can
/// create payloads; pipeline JSON never contains runtime objects.
public struct PipelineNodeValue: Sendable {
  public let type: PipelinePortType
  let payload: any Sendable

  public init<T: Sendable>(_ value: T, type: PipelinePortType) {
    self.type = type
    payload = value
  }

  public func value<T: Sendable>(as type: T.Type = T.self) -> T? {
    payload as? T
  }
}

public struct PipelineNodeExecutionContext: Sendable {
  public let semanticSHA256: String
  public let document: PipelineDocument?
  public let invocation: PipelineInvocation
  public let sourceMediaRoot: URL?
  /// Ports with outgoing graph connections. Nil means all outputs are requested.
  public let requestedOutputPorts: Set<String>?
  public let packageRootsByID: [String: URL]
  public let nodeIndex: Int
  public let nodeCount: Int
  public let progress: PipelineExecutionProgressHandler
  public let runID: UUID?

  public init(semanticSHA256: String, invocation: PipelineInvocation,
    sourceMediaRoot: URL?, packageRootsByID: [String: URL],
    nodeIndex: Int, nodeCount: Int,
    progress: @escaping PipelineExecutionProgressHandler, runID: UUID? = nil,
    requestedOutputPorts: Set<String>? = nil, document: PipelineDocument? = nil) {
    self.semanticSHA256 = semanticSHA256
    self.document = document
    self.invocation = invocation
    self.sourceMediaRoot = sourceMediaRoot
    self.requestedOutputPorts = requestedOutputPorts
    self.packageRootsByID = packageRootsByID
    self.nodeIndex = nodeIndex
    self.nodeCount = nodeCount
    self.progress = progress
    self.runID = runID
  }

  public func packageRoot(for reference: PipelineResourceReference) throws -> URL {
    guard let root = packageRootsByID[reference.packageID] else {
      throw PipelineEngineError.modelPackageUnavailable(
        "No local package is linked for \(reference.packageID).")
    }
    return root
  }
}

public struct PipelineNodeResult: Sendable {
  public var outputs: [String: PipelineNodeValue]
  public var terminalOutput: PipelineExecutionOutput?

  public init(
    outputs: [String: PipelineNodeValue] = [:],
    terminalOutput: PipelineExecutionOutput? = nil
  ) {
    self.outputs = outputs
    self.terminalOutput = terminalOutput
  }
}

/// Native semantics for one node kind. Implementations are installed by the
/// host, never decoded from a pipeline or imported ComfyUI workflow.
public struct PipelineNodeExecutor: Sendable {
  public typealias Validator = @Sendable (PipelineNode) -> [PipelineDiagnostic]
  public typealias Operation = @Sendable (
    PipelineNode, [String: PipelineNodeValue], PipelineNodeExecutionContext
  ) async throws -> PipelineNodeResult

  public let kind: PipelineNodeKind
  private let validator: Validator
  private let operation: Operation

  public init(
    kind: PipelineNodeKind,
    validate: @escaping Validator = { _ in [] },
    execute: @escaping Operation
  ) {
    self.kind = kind
    self.validator = validate
    operation = execute
  }

  public func validate(_ node: PipelineNode) -> [PipelineDiagnostic] {
    validator(node)
  }

  public func execute(
    _ node: PipelineNode,
    inputs: [String: PipelineNodeValue],
    context: PipelineNodeExecutionContext
  ) async throws -> PipelineNodeResult {
    try await operation(node, inputs, context)
  }
}
