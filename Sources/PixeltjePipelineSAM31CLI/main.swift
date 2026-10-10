import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineSegmentationRuntime

@main
private enum SAM31ExampleRunner {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("SAM 3.1 selection failed: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let traceURL = try PipelineTraceCLIOptions.takeDebugLog(from: &arguments)
    guard arguments.count.isMultiple(of: 2) else { throw usage() }
    var options: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
      guard arguments[index].hasPrefix("--"), options[arguments[index]] == nil else {
        throw usage()
      }
      options[arguments[index]] = arguments[index + 1]
    }
    guard let workflow = options["--workflow"],
      let image = options["--image"],
      let prompt = options["--prompt"],
      let output = options["--output"],
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      Set(options.keys).isSubset(of: ["--workflow", "--image", "--prompt", "--output", "--model-package"])
    else { throw usage() }

    let imageURL = URL(fileURLWithPath: image).standardizedFileURL
    let packageURL = options["--model-package"].map { URL(fileURLWithPath: $0) }
      ?? SAM31PipelineFamily.defaultPackageURL()
    var document = try PipelineJSON.decode(Data(contentsOf: URL(fileURLWithPath: workflow)))
    guard let source = document.nodes.firstIndex(where: { $0.kind.rawValue == "input.image" }),
      let promptNode = document.nodes.firstIndex(where: { $0.kind == .promptInput })
    else { throw PipelineEngineError.invalidInvocation("Workflow needs image and prompt input nodes.") }
    document.nodes[source].parameters["sourceName"] = .string(imageURL.lastPathComponent)
    document.nodes[promptNode].parameters["value"] = .string(prompt)
    if options["--model-package"] != nil {
      document = try SAM31PipelineFamily.linkPackage(in: document, at: packageURL)
    }

    let runner = SAM31PipelineRunner()
    let engine = try PixeltjePipelineEngine.makeDefault(
      additionalNodeDescriptors: [SAM31PipelineFamily.descriptor()],
      additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
        + [SAM31PipelineFamily.executor(runner: runner)])
    let validation = await engine.validate(document)
    guard validation.isValid else {
      throw PipelineEngineError.invalidInvocation("Invalid workflow: \(validation.diagnostics)")
    }
    let inspection = SAM31PipelineFamily.inspectPackage(at: packageURL, for: document)
    guard inspection.isUsable else {
      throw PipelineEngineError.modelPackageUnavailable(inspection.summary)
    }
    let traceLog = try traceURL.map { try PipelineTraceLog(url: $0) }
    let trace = traceLog?.handler()
    let result = try await engine.execute(
      document,
      sourceMediaRoot: imageURL.deletingLastPathComponent(),
      packageRootsByID: [SAM31PipelineFamily.packageID: packageURL],
      invocation: PipelineInvocation(), progress: { event in
        if event.stage == .generating {
          fputs("\(event.message)\n", stderr)
        }
      }, trace: trace)
    try await traceLog?.close()
    guard case .image(let generated) = result else {
      throw PipelineEngineError.invalidInvocation("Selection workflow did not return an image.")
    }
    try writePNG(generated, to: URL(fileURLWithPath: output))
    print(output)
  }

  private static func usage() -> PipelineEngineError {
    .invalidInvocation(
      "Usage: pixeltje-pipeline-run-sam31 --workflow FILE --image FILE --prompt TEXT --output FILE [--model-package DIR] [--debug-log FILE]")
  }

  private static func writePNG(_ image: PipelineGeneratedImage, to url: URL) throws {
    let pixels = image.width * image.height
    guard image.width > 0, image.height > 0,
      image.planarRGB.count == pixels * 3 else {
      throw PipelineEngineError.invalidInvocation("Selection image has incomplete pixels.")
    }
    var rgba = [UInt8](repeating: 255, count: pixels * 4)
    for pixel in 0..<pixels {
      for channel in 0..<3 {
        let value = image.planarRGB[channel * pixels + pixel]
        guard value.isFinite else {
          throw PipelineEngineError.invalidInvocation("Selection image has invalid pixels.")
        }
        let sRGB = image.encoding.normalizedSRGBComponent(from: value)
        rgba[pixel * 4 + channel] = UInt8((Double(min(max(sRGB, 0), 1)) * 255).rounded())
      }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let bitmap = CGImage(
        width: image.width, height: image.height,
        bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { throw PipelineEngineError.invalidInvocation("Could not create output PNG.") }
    CGImageDestinationAddImage(destination, bitmap, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PipelineEngineError.invalidInvocation("Could not finish output PNG.")
    }
  }
}
