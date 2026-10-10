import CoreAI
import Foundation
import Metal
import PixeltjePipelineDomain

/// Executes one linked Core AI image classifier through the shared pipeline engine.
/// The input contract is display-referred sRGB, resized into float32 NCHW in [0, 1].
actor PipelineCoreAIImageClassifier {
  private struct Configuration {
    let width: Int
    let height: Int
    let channels: Int
    let inputName: String
    let outputName: String
  }

  private struct Loaded {
    let url: URL
    let contentHash: String
    let model: AIModel
    let function: InferenceFunction
  }

  private let stream: ComputeStream
  private var loaded: Loaded?

  init(commandQueue: any MTLCommandQueue) {
    stream = ComputeStream(commandQueue: commandQueue)
  }

  static func executor(runner: PipelineCoreAIImageClassifier) -> PipelineNodeExecutor {
    PipelineNodeExecutor(kind: .coreAIImageClassifier, validate: diagnostics) {
      node, inputs, context in
      try await runner.execute(node: node, inputs: inputs, context: context)
    }
  }

  private static func diagnostics(_ node: PipelineNode) -> [PipelineDiagnostic] {
    do {
      _ = try configuration(node)
      return []
    } catch {
      return [.init(severity: .error, code: .invalidParameter,
        message: error.localizedDescription, nodeID: node.id)]
    }
  }

  private func execute(node: PipelineNode, inputs: [String: PipelineNodeValue],
    context: PipelineNodeExecutionContext) async throws -> PipelineNodeResult {
    guard let image = inputs["image"]?.value(as: PipelineImageInput.self) else {
      throw PipelineEngineError.invalidInvocation("Image Classifier needs an image input.")
    }
    guard let reference = node.resources["model"]?.linkedReference,
      reference.kind == .coreAIModel, reference.componentRole == "classifier",
      reference.functionName == "main" else {
      throw PipelineEngineError.modelPackageUnavailable(
        "Link a Core AI image classifier package before running.")
    }
    let settings = try Self.configuration(node)
    let root = try context.packageRoot(for: reference)
    let loaded = try await load(root, reference: reference)
    guard let descriptor = loaded.model.functionDescriptor(for: "main"),
      descriptor.inputNames == [settings.inputName],
      descriptor.outputNames.contains(settings.outputName),
      case .ndArray(let inputDescriptor) = descriptor.inputDescriptor(of: settings.inputName),
      inputDescriptor.shape == [1, settings.channels, settings.height, settings.width]
    else {
      throw PipelineEngineError.invalidInvocation(
        "The linked model's input or output does not match the Image Classifier settings.")
    }
    let pixels = Self.prepare(image, width: settings.width, height: settings.height,
      channels: settings.channels)
    var array = NDArray(shape: [1, settings.channels, settings.height, settings.width],
      scalarType: .float32)
    var view = array.mutableView(as: Float.self)
    view.copyElements(fromContentsOf: pixels)
    let pending = try loaded.function.encode(
      inputs: [settings.inputName: InferenceFunction.AsyncValue(array)], to: stream)
    guard let value = pending[settings.outputName], let output = try await value.ndArray else {
      throw PipelineEngineError.planningFailed(
        "The linked image classifier returned no \(settings.outputName) scores.")
    }
    try Task.checkCancellation()
    guard output.scalarType == .float32,
      output.shape.count == 2, output.shape[0] == 1,
      (2...4096).contains(output.shape[1]) else {
      throw PipelineEngineError.planningFailed(
        "Image Classifier needs a float32 [1, classCount] score output.")
    }
    let scores = output.view(as: Float.self).withUnsafePointer { pointer, _, _ in
      Array(UnsafeBufferPointer(start: pointer, count: output.shape[1]))
    }
    guard scores.allSatisfy(\.isFinite) else {
      throw PipelineEngineError.planningFailed(
        "Image Classifier returned nonfinite or empty scores.")
    }
    let winner = scores.indices.reduce(0) { scores[$1] > scores[$0] ? $1 : $0 }
    let labelText = node.parameters["classLabels"]?.stringValue ?? ""
    let labels = labelText
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if !labelText.isEmpty && (labels.count != scores.count
      || labels.contains(where: \.isEmpty)) {
      throw PipelineEngineError.invalidInvocation(
        "Image Classifier needs exactly \(scores.count) nonempty class labels.")
    }
    let prediction = labelText.isEmpty ? String(winner) : labels[winner]
    let scoreJSON = try JSONSerialization.data(withJSONObject: scores.map(Double.init))
    return PipelineNodeResult(outputs: [
      "prediction": .init(prediction, type: .string),
      "classIndex": .init(Int64(winner), type: .integer),
      "scores": .init(String(decoding: scoreJSON, as: UTF8.self), type: .string),
    ])
  }

  private func load(_ url: URL, reference: PipelineResourceReference) async throws -> Loaded {
    let root = url.standardizedFileURL.resolvingSymlinksInPath()
    let hashURL = root.appendingPathComponent("main.hash")
    let modelURL = root.appendingPathComponent("main.mlirb")
    guard ["aimodel", "aimodelc"].contains(root.pathExtension.lowercased()),
      FileManager.default.fileExists(atPath: modelURL.path),
      let data = try? Data(contentsOf: hashURL) else {
      throw PipelineEngineError.modelPackageUnavailable(
        "The selected classifier is not a complete .aimodel package.")
    }
    let hash: String
    if data.count == 32 {
      hash = data.map { String(format: "%02x", $0) }.joined()
    } else if let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      text.count == 64, text.allSatisfy(\.isHexDigit) {
      hash = text
    } else {
      throw PipelineEngineError.modelPackageUnavailable(
        "The selected classifier has no usable main.hash identity.")
    }
    guard reference.contentHash.lowercased() == hash,
      reference.packageVersion == "sha256.\(hash)",
      reference.packageID == "coreai.classifier.\(hash.prefix(16))" else {
      throw PipelineEngineError.modelPackageUnavailable(
        "The selected classifier has changed. Relink its .aimodel package.")
    }
    if let loaded, loaded.url == root, loaded.contentHash == hash { return loaded }
    let model = try await AIModel(contentsOf: root, options: .default)
    guard let function = try model.loadFunction(named: "main") else {
      throw PipelineEngineError.modelPackageUnavailable(
        "The selected classifier has no main function.")
    }
    let result = Loaded(url: root, contentHash: hash, model: model, function: function)
    loaded = result
    return result
  }

  private static func configuration(_ node: PipelineNode) throws -> Configuration {
    let width = try dimension("width", in: node, default: 28)
    let height = try dimension("height", in: node, default: 28)
    let channels = Int(node.parameters["channels"]?.integerValue ?? 1)
    let inputName = node.parameters["inputName"]?.stringValue ?? "image"
    let outputName = node.parameters["outputName"]?.stringValue ?? "scores"
    guard channels == 1 || channels == 3, width * height <= 1_048_576,
      !inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PipelineEngineError.invalidInvocation(
        "Image Classifier needs one or three channels, nonempty port names, and at most 1,048,576 pixels.")
    }
    return Configuration(width: width, height: height, channels: channels,
      inputName: inputName, outputName: outputName)
  }

  private static func dimension(_ name: String, in node: PipelineNode,
    default defaultValue: Int) throws -> Int {
    let value = Int(node.parameters[name]?.integerValue ?? Int64(defaultValue))
    guard (1...2048).contains(value) else {
      throw PipelineEngineError.invalidInvocation(
        "Image Classifier \(name) must be between 1 and 2048.")
    }
    return value
  }

  private static func prepare(_ image: PipelineImageInput, width: Int, height: Int,
    channels: Int) -> [Float] {
    let area = width * height
    var result = [Float](repeating: 0, count: area * channels)
    for y in 0..<height {
      let sourceY = min(max((Float(y) + 0.5) * Float(image.height) / Float(height) - 0.5,
        0), Float(image.height - 1))
      let y0 = Int(sourceY), y1 = min(y0 + 1, image.height - 1)
      let fy = sourceY - Float(y0)
      for x in 0..<width {
        let sourceX = min(max((Float(x) + 0.5) * Float(image.width) / Float(width) - 0.5,
          0), Float(image.width - 1))
        let x0 = Int(sourceX), x1 = min(x0 + 1, image.width - 1)
        let fx = sourceX - Float(x0)
        let offsets = [(y0 * image.width + x0) * 4,
          (y0 * image.width + x1) * 4,
          (y1 * image.width + x0) * 4,
          (y1 * image.width + x1) * 4]
        var rgb = [Float](repeating: 0, count: 3)
        for channel in 0..<3 {
          let top = image.rgba[offsets[0] + channel] * (1 - fx)
            + image.rgba[offsets[1] + channel] * fx
          let bottom = image.rgba[offsets[2] + channel] * (1 - fx)
            + image.rgba[offsets[3] + channel] * fx
          rgb[channel] = min(max(top * (1 - fy) + bottom * fy, 0), 1)
        }
        if channels == 1 {
          result[y * width + x] = rgb[0] * 0.299 + rgb[1] * 0.587 + rgb[2] * 0.114
        } else {
          for channel in 0..<3 { result[channel * area + y * width + x] = rgb[channel] }
        }
      }
    }
    return result
  }
}
