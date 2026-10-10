import CoreGraphics
import Foundation
import ImageIO
import OSLog
import PixeltjePipelineEngine
import PixeltjePipelineDomain
import UniformTypeIdentifiers

/// Image conversion and disk writes stay off the editor's main actor.
enum PipelineOutputWriter {
  private static let logger = Logger(
    subsystem: "org.pixeltje.PixeltjeMacApp", category: "pipeline-output")

  struct ScenePlanFailure: Encodable, Sendable {
    let recordedAt: Date
    let pipelineName: String
    let call: Int
    let seed: UInt64?
    let error: String
    let rawSceneWriterText: String
    let previousScenePlanJSON: String?
  }

  struct Saved: Sendable {
    let url: URL?
    let imageData: Data?
    let text: String?
  }

  struct PreviewBitmap: Sendable {
    let width: Int
    let height: Int
    let rgba: Data

    func cgImage() -> CGImage? {
      guard let provider = CGDataProvider(data: rgba as CFData),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    }
  }

  struct TurnRecord: Encodable, Sendable {
    let pipelineID: String
    let graphSHA256: String
    let call: Int
    let seed: UInt64?
    let x: Double?
    let y: Double?
    let previousState: String?
    let nextState: String
    let renderPrompt: String?
    let resources: [PipelineResourceReference]
  }

  static func saveTurn(_ record: TurnRecord, beside imageURL: URL) async throws {
    try await Task.detached(priority: .utility) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let url = imageURL.deletingPathExtension().appendingPathExtension("turn.json")
      try encoder.encode(record).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }.value
  }

  static func interactionPreviews(_ masks: [PipelineLabeledMask]) async throws -> [Data] {
    try await Task.detached(priority: .utility) {
      try masks.map { entry in
        try Task.checkCancellation()
        let mask = entry.mask
        var bytes = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for index in mask.coverage.indices {
          let alpha = UInt8((mask.coverage[index] * 100).rounded())
          bytes[index * 4] = alpha
          bytes[index * 4 + 1] = alpha
          bytes[index * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: mask.width, height: mask.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mask.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
      }
    }.value
  }

  static func save(
    _ output: PipelineExecutionOutput, to directory: URL,
    saveGeneratedImagesToDisk: Bool
  ) async throws -> Saved {
    let worker = Task.detached(priority: .userInitiated) {
      try saveSynchronously(
        output, to: directory, saveGeneratedImagesToDisk: saveGeneratedImagesToDisk)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  static func saveScenePlanFailure(_ failure: ScenePlanFailure) async throws -> URL {
    let worker = Task.detached(priority: .utility) {
      try saveScenePlanFailureSynchronously(failure)
    }
    return try await worker.value
  }

  private static func saveScenePlanFailureSynchronously(
    _ failure: ScenePlanFailure
  ) throws -> URL {
    let fileManager = FileManager.default
    let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    let directory = library
      .appendingPathComponent("Logs/Pixeltje/ScenePlans", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let url = directory.appendingPathComponent(
      "failure-\(UUID().uuidString.lowercased()).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(failure).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let files = (try? fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let failures = files
      .filter { $0.lastPathComponent.hasPrefix("failure-") && $0.pathExtension == "json" }
      .sorted {
        let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
        return (lhs ?? .distantPast) > (rhs ?? .distantPast)
      }
    for oldFile in failures.dropFirst(20) { try? fileManager.removeItem(at: oldFile) }
    return url
  }

  static func previewData(
    from output: PipelineGeneratedImage, maxDimension: Int? = 512
  ) async throws -> Data {
    let worker = Task.detached(priority: .utility) {
      try pngData(from: output, maxDimension: maxDimension)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  /// In-memory previews avoid PNG compression on every live shader frame.
  static func previewBitmap(
    from output: PipelineGeneratedImage, maxDimension: Int? = 512
  ) async throws -> PreviewBitmap {
    let worker = Task.detached(priority: .utility) {
      let (width, height, rgba) = try rgba(from: output, maxDimension: maxDimension)
      return PreviewBitmap(width: width, height: height, rgba: Data(rgba))
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  static func feedbackImage(from output: PipelineGeneratedImage) async throws -> PipelineImageInput {
    let worker = Task.detached(priority: .userInitiated) {
      let (width, height, bytes) = try rgba(from: output, maxDimension: nil)
      var floats = [Float](repeating: 0, count: bytes.count)
      for index in bytes.indices {
        if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
        floats[index] = Float(bytes[index]) / 255
      }
      for pixel in 0..<(width * height) {
        let alpha = floats[pixel * 4 + 3]
        for channel in 0..<3 { floats[pixel * 4 + channel] *= alpha }
      }
      return try PipelineImageInput(width: width, height: height, rgba: floats)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private static func saveSynchronously(
    _ output: PipelineExecutionOutput, to directory: URL,
    saveGeneratedImagesToDisk: Bool
  ) throws -> Saved {
    try Task.checkCancellation()
    switch output {
    case .none:
      return Saved(url: nil, imageData: nil, text: nil)
    case .image(let image):
      let preview = try pngData(from: image, maxDimension: 512)
      guard saveGeneratedImagesToDisk else {
        return Saved(url: nil, imageData: preview, text: nil)
      }
      let state = try image.nextStateJSON.map(PipelineStateJSON.canonicalObject)
      let data = try pngData(from: image, maxDimension: nil)
      let url = try write(data, extension: "png", hash: image.semanticPipelineSHA256,
        to: directory)
      if let state {
        // State is required for a committed turn: propagate write failures.
        let sidecar = url.deletingPathExtension().appendingPathExtension("state.json")
        try Data(state.utf8).write(to: sidecar, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
      }
      if let scenePlanJSON = image.scenePlanJSON {
        let sidecar = url.deletingPathExtension().appendingPathExtension("sceneplan.json")
        do {
          try Data(scenePlanJSON.utf8).write(to: sidecar, options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
        } catch {
          logger.error(
            "Could not save scene-plan sidecar: \(error.localizedDescription, privacy: .public)")
        }
      }
      if let feedbackText = image.feedbackText {
        let sidecar = url.deletingPathExtension().appendingPathExtension("feedback.txt")
        do {
          try Data(feedbackText.utf8).write(to: sidecar, options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
        } catch {
          logger.error(
            "Could not save image text sidecar: \(error.localizedDescription, privacy: .public)")
        }
      }
      return Saved(url: url, imageData: preview, text: nil)
    case .text(let result):
      return Saved(url: try write(Data(result.text.utf8), extension: "txt",
        hash: result.semanticPipelineSHA256, to: directory), imageData: nil,
        text: result.text)
    case .plainText(let result):
      return Saved(url: try write(Data(result.text.utf8), extension: "txt",
        hash: result.semanticPipelineSHA256, to: directory), imageData: nil,
        text: result.text)
    case .video(let result):
      return Saved(url: try copy(result.fileURL, hash: result.semanticPipelineSHA256,
        to: directory), imageData: nil, text: nil)
    case .videoFrame(let frame):
      return Saved(url: nil,
        imageData: try pngData(from: frame.image, maxDimension: 512), text: nil)
    case .audio(let result):
      return Saved(url: try copy(result.fileURL, hash: result.semanticPipelineSHA256,
        to: directory), imageData: nil, text: nil)
    case .model(let result):
      let loss = result.validationLoss.map { String(format: "%.6f", $0) } ?? "unavailable"
      let validationAccuracy = result.validationAccuracy.map {
        "\nValidation accuracy: \(String(format: "%.2f", $0 * 100))%"
      } ?? ""
      let testAccuracy = result.testAccuracy.map {
        "\nHeld-out test accuracy: \(String(format: "%.2f", $0 * 100))%"
      } ?? ""
      return Saved(url: result.assetURL, imageData: nil,
        text: "Trained model: \(result.assetURL.path)\nCheckpoint: \(result.checkpointURL.path)\nValidation loss: \(loss)\(validationAccuracy)\(testAccuracy)")
    }
  }

  private static func write(
    _ data: Data, extension ext: String, hash: String, to directory: URL
  ) throws -> URL {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let filename = "output-\(hash.prefix(12))-\(UUID().uuidString.lowercased()).\(ext)"
    let url = directory.appendingPathComponent(filename)
    try data.write(to: url, options: .atomic)
    if Task.isCancelled {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    return url
  }

  private static func copy(_ source: URL, hash: String, to directory: URL) throws -> URL {
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
    let filename = "output-\(hash.prefix(12))-\(UUID().uuidString.lowercased()).\(ext)"
    let url = directory.appendingPathComponent(filename)
    try FileManager.default.copyItem(at: source, to: url)
    if Task.isCancelled {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    return url
  }

  private static func pngData(
    from output: PipelineGeneratedImage, maxDimension: Int?
  ) throws -> Data {
    let (width, height, bytes) = try rgba(from: output, maxDimension: maxDimension)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    else { throw PipelineEditorError.cannotEncodeGeneratedOutput }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)
    else { throw PipelineEditorError.cannotEncodeGeneratedOutput }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PipelineEditorError.cannotEncodeGeneratedOutput
    }
    return data as Data
  }

  private static func rgba(
    from output: PipelineGeneratedImage, maxDimension: Int?
  ) throws -> (Int, Int, [UInt8]) {
    let (pixelCount, overflow) = output.width.multipliedReportingOverflow(by: output.height)
    guard output.width > 0, output.height > 0, !overflow,
      pixelCount <= Int.max / 4, output.planarRGB.count == pixelCount * 3,
      output.alpha.map({ $0.count == pixelCount && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) ?? true
    else { throw PipelineEditorError.cannotEncodeGeneratedOutput }
    let scale = maxDimension.map {
      min(1, Double($0) / Double(max(output.width, output.height)))
    } ?? 1
    let width = max(1, Int((Double(output.width) * scale).rounded()))
    let height = max(1, Int((Double(output.height) * scale).rounded()))
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      if y.isMultiple(of: 32) { try Task.checkCancellation() }
      let sourceY = min(output.height - 1, y * output.height / height)
      for x in 0..<width {
        let sourceX = min(output.width - 1, x * output.width / width)
        let sourceIndex = sourceY * output.width + sourceX
        let alpha = output.alpha?[sourceIndex] ?? 1
        bytes[(y * width + x) * 4 + 3] = UInt8((alpha * 255).rounded())
        for channel in 0..<3 {
          let value = output.planarRGB[channel * pixelCount + sourceIndex]
          guard value.isFinite else { throw PipelineEditorError.cannotEncodeGeneratedOutput }
          let normalized = min(max(output.encoding.normalizedSRGBComponent(from: value), 0), 1)
          bytes[(y * width + x) * 4 + channel] = UInt8((normalized * 255).rounded())
        }
      }
    }
    return (width, height, bytes)
  }
}
