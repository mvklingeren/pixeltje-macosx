import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineBaseTestSetRuntime

private enum RunnerError: Error, LocalizedError {
  case message(String)

  var errorDescription: String? {
    guard case .message(let text) = self else { return nil }
    return text
  }
}

private actor PreviewCollector {
  private var images: [PipelineGeneratedImage] = []

  func append(_ image: PipelineGeneratedImage) { images.append(image) }
  func take() -> [PipelineGeneratedImage] { images }
}

private struct RunOverride {
  let stem: String
  let parameterID: String
  let rawValue: String
}

@main
private struct PipelineRunner {
  private static let usage = """
    Usage:
      pixeltje-pipeline-run --workflow FILE --output-dir DIR [--run-loop] [--debug-log FILE]
      pixeltje-pipeline-run-base-test-set --test-set DIR --output-dir DIR [--override WORKFLOW:PARAMETER=VALUE]... [--debug-log FILE]

    Executes each workflow once (frame or Loop call index 0), including Metal Render.
    --run-loop records every frame of a finite image-to-video Loop or Timeline to one MP4.
    Output directory must be empty. Reports execution and output-saving times.
    Single-workflow mode saves the final output; test-set mode also saves previews.
    """

  static func main() async {
    do {
      try await run()
    } catch {
      fputs("Pipeline run failed: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      writeLine(usage)
      return
    }
    let traceURL = try PipelineTraceCLIOptions.takeDebugLog(from: &arguments)
    let runLoop: Bool
    if let index = arguments.firstIndex(of: "--run-loop") {
      arguments.remove(at: index)
      runLoop = true
    } else {
      runLoop = false
    }
    guard arguments.count >= 4, arguments.count.isMultiple(of: 2),
      ["--test-set", "--workflow"].contains(arguments[0]),
      arguments[2] == "--output-dir" else {
      throw RunnerError.message(usage)
    }
    let singleWorkflow = arguments[0] == "--workflow"
    guard !runLoop || singleWorkflow else {
      throw RunnerError.message("--run-loop requires --workflow.")
    }
    guard !singleWorkflow || arguments.count == 4 else {
      throw RunnerError.message(usage)
    }
    var overrides: [RunOverride] = []
    for index in stride(from: 4, to: arguments.count, by: 2) {
      guard arguments[index] == "--override",
        let colon = arguments[index + 1].firstIndex(of: ":"),
        let equals = arguments[index + 1].firstIndex(of: "="), colon < equals
      else { throw RunnerError.message("Invalid --override syntax.") }
      let value = arguments[index + 1]
      overrides.append(RunOverride(
        stem: String(value[..<colon]),
        parameterID: String(value[value.index(after: colon)..<equals]),
        rawValue: String(value[value.index(after: equals)...])))
    }
    guard Set(overrides.map(\.stem)).count == overrides.count else {
      throw RunnerError.message("Only one override run per workflow is supported.")
    }
    let source = URL(fileURLWithPath: arguments[1], isDirectory: !singleWorkflow)
    let sourceRoot = singleWorkflow ? source.deletingLastPathComponent() : source
    let outputRoot = URL(fileURLWithPath: arguments[3], isDirectory: true)
    let files = singleWorkflow ? [source] : try FileManager.default.contentsOfDirectory(
      at: sourceRoot, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".pixpipeline.json") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw RunnerError.message("No pipeline files found.") }
    let stems = Set(files.map { $0.lastPathComponent.replacingOccurrences(
      of: ".pixpipeline.json", with: "") })
    guard overrides.allSatisfy({ stems.contains($0.stem) }) else {
      throw RunnerError.message("An override names an unknown workflow.")
    }
    try FileManager.default.createDirectory(
      at: outputRoot, withIntermediateDirectories: true)
    guard try FileManager.default.contentsOfDirectory(atPath: outputRoot.path).isEmpty else {
      throw RunnerError.message("Output directory must be empty: \(outputRoot.path)")
    }
    let workflows = try files.map { file in
      (file: file, document: try PipelineJSON.decode(Data(contentsOf: file)))
    }
    let requiresMetal = workflows.contains { workflow in
      workflow.document.nodes.contains {
        ($0.kind == .renderMetal || $0.kind == .gpuProgram)
          && $0.executionState == .enabled
      }
    }
    let executors = BaseTestSetPipelineFamily.makeNodeExecutors()
    let engine = requiresMetal
      ? try PixeltjePipelineEngine.makeDefault(additionalNodeExecutors: executors)
      : PixeltjePipelineEngine(additionalNodeExecutors: executors)
    writeLine("Renderer: \(await engine.snapshot().deviceName)")
    let traceLog = try traceURL.map { try PipelineTraceLog(url: $0) }
    let trace = traceLog?.handler()

    for (file, original) in workflows {
      let stem = file.lastPathComponent.replacingOccurrences(
        of: ".pixpipeline.json", with: "")
      let runs: [RunOverride?] = [nil] + overrides.filter { $0.stem == stem }.map(Optional.some)
      for runOverride in runs {
        let label = stem + (runOverride == nil ? "" : "-override")
        writeLine("\(label): starting")
        var document = original
        if let runOverride { try apply(runOverride, to: &document) }
        let report = await engine.validate(document)
        guard report.isValid, report.warnings.isEmpty else {
          throw RunnerError.message("\(file.lastPathComponent) failed graph validation: \(report.diagnostics)")
        }
        let inspection = try await engine.inspectPackage(for: document, at: sourceRoot)
        guard inspection.isUsable else {
          throw RunnerError.message("\(file.lastPathComponent): \(inspection.summary)")
        }
        if runLoop {
          let registry = PipelineNodeRegistry.coreAIV1
          let activeLoop = PipelineControlFlow.activeLoop(in: document, registry: registry)
          let activeTimeline = PipelineControlFlow.activeTimeline(in: document, registry: registry)
          let calls = activeTimeline?.settings.frameCount ?? activeLoop?.settings.maxCalls
          guard let calls,
            activeTimeline != nil || (activeLoop?.settings.feedback == nil
              && activeLoop?.settings.autoPause == false
              && activeLoop?.settings.seedStrategy == .fixed),
            let output = PipelineGraphOutputs.selectedOutputNode(
              in: document, registry: registry),
            output.kind == .videoOutput,
            document.connections.contains(where: {
              $0.input == .init(nodeID: output.id, port: "image")
            }) else {
            throw RunnerError.message(
              "--run-loop needs a finite Image → Video Output Loop or Timeline without pause or feedback.")
          }
          let url = outputRoot.appendingPathComponent(label + ".mp4")
          var writer: PipelineStreamingVideoWriter?
          let started = DispatchTime.now().uptimeNanoseconds
          do {
            for index in 0..<calls {
              try Task.checkCancellation()
              let result = try await engine.execute(
                document, sourceMediaRoot: sourceRoot,
                packageRootsByID: [:], invocation: PipelineInvocation(values: [
                  PipelineInvocation.loopCallIndexKey: .integer(Int64(index)),
                ]), trace: trace, traceCall: index + 1)
              guard case .videoFrame(let frame) = result else {
                throw RunnerError.message("Loop call \(index + 1) did not produce a video frame.")
              }
              if writer == nil {
                writer = try PipelineStreamingVideoWriter(outputURL: url,
                  framesPerSecond: frame.framesPerSecond)
              }
              try await writer?.append(frame)
              if (index + 1).isMultiple(of: 10) || index + 1 == calls {
                writeLine("  recorded \(index + 1)/\(calls) frames")
              }
            }
            guard let writer else { throw RunnerError.message("Loop produced no frames.") }
            let video = try await writer.finish()
            let completed = DispatchTime.now().uptimeNanoseconds
            writeLine("\(label): saved \(video.frameCount) frames at \(video.framesPerSecond) fps → \(url.path)")
            writeLine(String(format: "  Total: %.3f sec",
              Double(completed - started) / 1_000_000_000))
          } catch {
            await writer?.cancel()
            throw error
          }
          continue
        }
        let previewCollector = PreviewCollector()
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await engine.execute(
          document, sourceMediaRoot: sourceRoot,
          packageRootsByID: [:], invocation: PipelineInvocation(values: [
            PipelineInvocation.loopCallIndexKey: .integer(0),
          ]),
          progress: { event in
            if !singleWorkflow, let image = event.preview { await previewCollector.append(image) }
            if stem == "05-video-resize-with-audio", event.stage == .generating {
              try? FileHandle.standardOutput.write(contentsOf: Data(
                "  \(event.completedUnitCount + 1)/\(event.totalUnitCount): \(event.message)\n".utf8))
            }
          }, trace: trace)
        let executed = DispatchTime.now().uptimeNanoseconds
        let resultDescription: String
        switch result {
        case .none:
          resultDescription = "completed without an outcome"
        case .plainText(let value):
          let url = outputRoot.appendingPathComponent(label + ".txt")
          try value.text.write(to: url, atomically: true, encoding: .utf8)
          resultDescription = "text → \(url.lastPathComponent)"
        case .image(let value):
          let url = outputRoot.appendingPathComponent(label + ".png")
          try writePNG(value, to: url)
          let previews = await previewCollector.take()
          for (index, preview) in previews.enumerated() {
            try writePNG(preview, to: outputRoot.appendingPathComponent(
              "\(label)-preview-\(index + 1).png"))
          }
          resultDescription = "\(value.width) × \(value.height) PNG → \(url.lastPathComponent)"
        case .video(let value):
          let url = outputRoot.appendingPathComponent(label + ".mp4")
          if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
          }
          try FileManager.default.moveItem(at: value.fileURL, to: url)
          resultDescription = "\(value.width) × \(value.height), \(value.frameCount) frames → \(url.lastPathComponent)"
        case .videoFrame(let frame):
          let url = outputRoot.appendingPathComponent(label + ".mp4")
          let writer = try PipelineStreamingVideoWriter(outputURL: url,
            framesPerSecond: frame.framesPerSecond)
          do {
            try await writer.append(frame)
            let video = try await writer.finish()
            resultDescription = "\(video.width) × \(video.height), 1 frame → \(url.lastPathComponent)"
          } catch {
            await writer.cancel()
            throw error
          }
        case .audio(let value):
          let url = outputRoot.appendingPathComponent(label + ".wav")
          try FileManager.default.copyItem(at: value.fileURL, to: url)
          resultDescription = "WAV → \(url.lastPathComponent)"
        case .text:
          throw RunnerError.message("This runner supports model-free workflows only.")
        case .model:
          throw RunnerError.message("This runner does not train models.")
        }
        let saved = DispatchTime.now().uptimeNanoseconds
        writeLine("\(label): executed, \(resultDescription)")
        writeLine(String(format: "  Execution: %.3f ms · saving: %.3f ms · total: %.3f ms",
          Double(executed - started) / 1_000_000,
          Double(saved - executed) / 1_000_000,
          Double(saved - started) / 1_000_000))
      }
    }
    try await traceLog?.close()
    writeLine("Outputs: \(outputRoot.path)")
  }

  private static func apply(_ runOverride: RunOverride, to document: inout PipelineDocument) throws {
    guard let exposed = document.exposedParameters.first(where: { $0.id == runOverride.parameterID }),
      let nodeIndex = document.nodes.firstIndex(where: { $0.id == exposed.target.nodeID })
    else { throw RunnerError.message("Unknown exposed parameter \(runOverride.parameterID).") }
    let value: PipelineValue
    switch exposed.valueType {
    case .string:
      value = .string(runOverride.rawValue)
    case .boolean:
      guard runOverride.rawValue == "true" || runOverride.rawValue == "false" else {
        throw RunnerError.message("Override \(exposed.id) must be true or false.")
      }
      value = .boolean(runOverride.rawValue == "true")
    case .integer:
      guard let integer = Int64(runOverride.rawValue) else {
        throw RunnerError.message("Override \(exposed.id) must be an integer.")
      }
      if let minimum = exposed.minimum, Double(integer) < minimum { throw RunnerError.message("Override is below minimum.") }
      if let maximum = exposed.maximum, Double(integer) > maximum { throw RunnerError.message("Override is above maximum.") }
      value = .integer(integer)
    case .number:
      guard let number = Double(runOverride.rawValue), number.isFinite else {
        throw RunnerError.message("Override \(exposed.id) must be a finite number.")
      }
      if let minimum = exposed.minimum, number < minimum { throw RunnerError.message("Override is below minimum.") }
      if let maximum = exposed.maximum, number > maximum { throw RunnerError.message("Override is above maximum.") }
      value = .number(number)
    default:
      throw RunnerError.message("Override type \(exposed.valueType.rawValue) is unsupported by this CLI.")
    }
    document.nodes[nodeIndex].parameters[exposed.target.parameter] = value
  }

  private static func writeLine(_ message: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data("\(message)\n".utf8))
  }

  private static func writePNG(_ image: PipelineGeneratedImage, to url: URL) throws {
    let count = image.width * image.height
    guard image.width > 0, image.height > 0,
      image.planarRGB.count == count * 3,
      image.alpha.map({ $0.count == count && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) ?? true else {
      throw RunnerError.message("Invalid generated image buffer.")
    }
    var rgba = [UInt8](repeating: 255, count: count * 4)
    for pixel in 0..<count {
      let alpha = image.alpha?[pixel] ?? 1
      rgba[pixel * 4 + 3] = UInt8((alpha * 255).rounded())
      for channel in 0..<3 {
        let value = image.planarRGB[channel * count + pixel]
        guard value.isFinite else { throw RunnerError.message("Image contains non-finite pixels.") }
        let sRGB = image.encoding.normalizedSRGBComponent(from: value)
        rgba[pixel * 4 + channel] = UInt8(
          (min(max(Double(sRGB), 0), 1) * Double(alpha) * 255).rounded())
      }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let bitmap = CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { throw RunnerError.message("Could not create \(url.lastPathComponent).") }
    CGImageDestinationAddImage(destination, bitmap, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw RunnerError.message("Could not write \(url.lastPathComponent).")
    }
  }
}
