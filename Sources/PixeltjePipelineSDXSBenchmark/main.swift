import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineResourceLinking
import PixeltjePipelineSDXSRuntime
import PixeltjePipelineTextRuntime

@main
enum SDXSBenchmark {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("SDXS benchmark failed: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard (args.count == 6 || args.count == 7), let seed = UInt32(args[3]),
      let runs = Int(args[4]), runs > 0
    else { throw BenchmarkError.invalidArguments }
    let workflowURL = URL(fileURLWithPath: args[0])
    let packageURL = URL(fileURLWithPath: args[1], isDirectory: true)
    let prompt = args[2]
    let outputDirectory = URL(fileURLWithPath: args[5], isDirectory: true)
    let textPackageURL = args.count == 7
      ? URL(fileURLWithPath: args[6], isDirectory: true) : nil
    let document = try PipelineJSON.decode(Data(contentsOf: workflowURL))
    let engine = try PixeltjePipelineEngine.makeDefault(
      additionalNodeDescriptors: [
        SDXSPipelineFamily.descriptor(),
        CoreAITextPipelineFamily.makeCompositeNodeDescriptor(),
      ],
      additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
        + [SDXSPipelineFamily.executor(runner: SDXSPipelineRunner()),
           CoreAITextPipelineFamily.makeNodeExecutor(runner: CoreAITextPipelineRunner())])
    _ = try await engine.prepare(document)
    guard let node = document.nodes.first(where: { $0.kind == SDXSPipelineFamily.nodeKind })
    else { throw BenchmarkError.missingNode }
    if let error = SDXSPipelineFamily.inspectPackage(at: packageURL, for: document) {
      throw BenchmarkError.package(error)
    }
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    let runner = SDXSPipelineRunner()
    var previousPlan: String?
    for index in 0..<runs {
      let requestedSeed = textPackageURL == nil ? UInt64(seed) + UInt64(index) : UInt64(seed)
      guard let runSeed = UInt32(exactly: requestedSeed) else {
        throw BenchmarkError.invalidArguments
      }
      let start = DispatchTime.now().uptimeNanoseconds
      let textTelemetry = TextTelemetry()
      let image: PipelineGeneratedImage
      if let textPackageURL {
        var values: [String: PipelineInvocationValue] = [
          PipelineInvocation.loopCallIndexKey: .integer(Int64(index)),
        ]
        if let previousPlan {
          values[PipelineInvocation.previousScenePlanKey] = .string(previousPlan)
          if let region = try? PipelineScenePlan.decode(previousPlan).regions.last {
            values[PipelineInvocation.trackpadXKey] = .number((region.box[0] + region.box[2]) / 2)
            values[PipelineInvocation.trackpadYKey] = .number((region.box[1] + region.box[3]) / 2)
          }
        }
        let output: PipelineExecutionOutput
        do {
          output = try await engine.execute(
            document, packageRootsByID: [
              SDXSPipelineFamily.packageID: packageURL,
              "coreai.qwen-qwen3-0-6b": textPackageURL,
            ], invocation: PipelineInvocation(values: values), progress: { update in
              await textTelemetry.record(update)
            })
        } catch {
          if let summary = await textTelemetry.summary(from: start) {
            fputs("Qwen3: input \(summary.input), output \(summary.output) tokens at +\(summary.seconds)s\n", stderr)
          }
          if let response = await textTelemetry.latestResponse() {
            let failureURL = outputDirectory.appendingPathComponent("qwen-response-\(index + 1).txt")
            try? response.write(to: failureURL, atomically: true, encoding: .utf8)
            fputs("Qwen3 response: \(failureURL.path)\n", stderr)
          }
          throw error
        }
        guard case .image(let generated) = output else {
          throw BenchmarkError.invalidImage
        }
        image = generated
        previousPlan = image.scenePlanJSON
      } else {
        image = try await runner.generate(
          at: packageURL, node: node, prompt: prompt, seed: runSeed,
          semanticSHA256: document.id.rawValue)
      }
      let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
      let file = outputDirectory.appendingPathComponent("sdxs-\(index + 1).png")
      try writePNG(image, to: file)
      if let plan = image.scenePlanJSON {
        try plan.write(
          to: outputDirectory.appendingPathComponent("sdxs-\(index + 1).sceneplan.json"),
          atomically: true, encoding: .utf8)
      }
      let record: [String: Any] = [
        "run": index + 1, "seed": runSeed, "seconds": seconds,
        "mode": textPackageURL == nil ? "image-node" : "full-graph",
        "width": image.width, "height": image.height, "output": file.path,
        "scenePlanCharacters": image.scenePlanJSON?.count ?? 0,
      ]
      if textPackageURL != nil, let summary = await textTelemetry.summary(from: start) {
        fputs("Qwen3: input \(summary.input) tokens, output \(summary.output) tokens, last text update at +\(summary.seconds)s\n", stderr)
      }
      let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      print(String(decoding: data, as: UTF8.self))
      fflush(stdout)
    }
  }

  private static func writePNG(_ output: PipelineGeneratedImage, to url: URL) throws {
    let count = output.width * output.height
    guard output.planarRGB.count == count * 3 else { throw BenchmarkError.invalidImage }
    var pixels = [UInt8](repeating: 255, count: count * 4)
    for index in 0..<count {
      for channel in 0..<3 {
        let value = output.planarRGB[channel * count + index]
        guard value.isFinite else { throw BenchmarkError.invalidImage }
        let sRGB = output.encoding.normalizedSRGBComponent(from: value)
        pixels[index * 4 + channel] = UInt8((min(max(sRGB, 0), 1) * 255).rounded())
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
    else { throw BenchmarkError.invalidImage }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BenchmarkError.invalidImage }
  }
}

private actor TextTelemetry {
  private var input: Int?
  private var output: Int?
  private var lastUpdate: UInt64?
  private var response: String?

  func record(_ progress: PipelineExecutionProgress) {
    guard progress.activeNodeIDs.contains(PipelineNodeID(rawValue: "characterWriter")),
      progress.outputTokenCount != nil
    else { return }
    input = progress.inputTokenCount
    output = progress.outputTokenCount
    lastUpdate = DispatchTime.now().uptimeNanoseconds
    response = progress.generatedText
  }

  func latestResponse() -> String? { response }

  func summary(from start: UInt64) -> (input: Int, output: Int, seconds: Double)? {
    guard let lastUpdate else { return nil }
    return (input ?? -1, output ?? -1, Double(lastUpdate - start) / 1_000_000_000)
  }
}

private enum BenchmarkError: LocalizedError {
  case invalidArguments
  case missingNode
  case package(String)
  case invalidImage

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      "Usage: pixeltje-pipeline-benchmark-sdxs WORKFLOW SDXS_PACKAGE PROMPT SEED RUNS OUTPUT_DIR [QWEN_PACKAGE]"
    case .missingNode: "The workflow has no SDXS generation node."
    case .package(let message): message
    case .invalidImage: "The SDXS runtime returned invalid image pixels."
    }
  }
}
