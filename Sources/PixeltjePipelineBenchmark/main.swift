import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineFLUX2Runtime

@main
enum PipelineBenchmark {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("Benchmark failed: \(error)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let traceURL = try PipelineTraceCLIOptions.takeDebugLog(from: &args)
    guard args.count == 6,
      let seed = UInt32(args[3]),
      let count = Int(args[4]), count > 0
    else {
      throw BenchmarkError.invalidArguments
    }
    let pipelineURL = URL(fileURLWithPath: args[0])
    let packageURL = URL(fileURLWithPath: args[1], isDirectory: true)
    let prompt = args[2]
    let outputDirectory = URL(fileURLWithPath: args[5], isDirectory: true)
    let document = try PipelineJSON.decode(Data(contentsOf: pipelineURL))
    let runner = FLUX2KleinPipelineRunner()
    let engine = try PixeltjePipelineEngine.makeDefault(
      additionalNodeDescriptors: [FLUX2KleinPipelineFamily.makeCompositeNodeDescriptor()],
      additionalNodeExecutors: [FLUX2KleinPipelineFamily.makeNodeExecutor(runner: runner)])
    let inspection = await FLUX2KleinPipelineFamily.inspectPackageForExecution(
      at: packageURL, for: document)
    guard inspection.isUsable else {
      throw BenchmarkError.package(inspection.summary)
    }
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    let traceLog = try traceURL.map { try PipelineTraceLog(url: $0) }
    let trace = traceLog?.handler()
    let traceRunID = UUID()
    for index in 0..<count {
      guard let runSeed = UInt32(exactly: UInt64(seed) + UInt64(index)) else {
        throw BenchmarkError.invalidArguments
      }
      let invocation = PipelineInvocation(values: [
        PipelineInvocation.promptKey: .string(prompt),
        PipelineInvocation.negativePromptKey: .string(""),
        PipelineInvocation.seedKey: .unsignedInteger(UInt64(runSeed)),
        PipelineInvocation.widthKey: .integer(1024),
        PipelineInvocation.heightKey: .integer(1024),
        PipelineInvocation.stepsKey: .integer(4),
        PipelineInvocation.guidanceKey: .number(1),
      ])
      let start = DispatchTime.now().uptimeNanoseconds
      let output = try await engine.execute(
        document,
        packageRootsByID: [FLUX2KleinPipelineFamily.packageID: packageURL],
        invocation: invocation, trace: trace, traceRunID: traceRunID, traceCall: index + 1)
      let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
      guard case .image(let image) = output else {
        throw BenchmarkError.nonImageOutput
      }
      let file = outputDirectory.appendingPathComponent("pipeline-\(index + 1).png")
      try writePNG(image, to: file)
      let record: [String: Any] = [
        "runtime": "pixel_pipeline",
        "run": index + 1,
        "seed": runSeed,
        "seconds": seconds,
        "width": image.width,
        "height": image.height,
        "semanticPipelineSHA256": image.semanticPipelineSHA256,
        "output": file.path,
      ]
      let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      print(String(decoding: data, as: UTF8.self))
      fflush(stdout)
    }
    try await traceLog?.close()
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
        pixels[index * 4 + channel] = UInt8(
          (min(max(sRGB, 0), 1) * 255).rounded())
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

private enum BenchmarkError: LocalizedError {
  case invalidArguments
  case package(String)
  case nonImageOutput
  case invalidImage

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      "Usage: pixeltje-pipeline-benchmark PIPELINE PACKAGE PROMPT SEED RUNS OUTPUT_DIR [--debug-log FILE]"
    case .package(let message): message
    case .nonImageOutput: "The pipeline did not produce an image."
    case .invalidImage: "The pipeline returned invalid image pixels."
    }
  }
}
