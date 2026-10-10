import CoreGraphics
import Foundation
import ImageIO
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
import PixeltjePipelineEngine
import PixeltjePipelineResourceLinking
import Testing

@Test func mnistInferenceWorkflowLinksModelWithoutSavingItsPath() async throws {
  let original = PipelineImageClassifierPackage.mnistWorkflow()
  #expect(original.nodes.map(\.kind.rawValue) == [
    "input.image", "coreai.imageClassifier", "output.text",
  ])
  let json = String(decoding: try PipelineJSON.encode(original), as: UTF8.self)
  #expect(!json.contains("Model Runs"))
  #expect(!json.contains(".aimodel/"))
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let exampleURL = repository.appendingPathComponent(
    "Examples/model-inference-mnist.pixpipeline.json")
  let example = try PipelineJSON.decode(Data(contentsOf: exampleURL))
  #expect(example.nodes.map(\.kind) == original.nodes.map(\.kind))

  guard let modelPath = ProcessInfo.processInfo.environment["PIXELTJE_MNIST_CLASSIFIER_MODEL"],
    let datasetPath = ProcessInfo.processInfo.environment["PIXELTJE_MNIST_DATASET"],
    let python = ProcessInfo.processInfo.environment["PIXELTJE_TRAINING_TEST_PYTHON"]
  else { return }
  let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
  let linked = try PipelineImageClassifierPackage.link(example,
    at: modelURL, replacingPackageID: PipelineImageClassifierPackage.unlinkedPackageID)
  #expect(PipelineImageClassifierPackage.inspect(linked.document,
    at: modelURL, packageID: linked.packageID) == nil)
  let linkedJSON = String(decoding: try PipelineJSON.encode(linked.document), as: UTF8.self)
  #expect(!linkedJSON.contains(modelPath))

  let sample = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pixeltje-mnist-inference-\(UUID().uuidString).raw")
  defer { try? FileManager.default.removeItem(at: sample) }
  let extraction = Process()
  extraction.executableURL = URL(fileURLWithPath: python)
  extraction.arguments = ["-c", """
    import numpy as np
    import sys
    with np.load(sys.argv[1], allow_pickle=False) as data:
        assert int(data['y_test'][0]) == 7
        open(sys.argv[2], 'wb').write(data['x_test'][0].tobytes())
    """, datasetPath, sample.path]
  try extraction.run()
  extraction.waitUntilExit()
  #expect(extraction.terminationStatus == 0)
  let grayscale = [UInt8](try Data(contentsOf: sample))
  #expect(grayscale.count == 784)
  let rgba = grayscale.flatMap { value -> [Float] in
    let component = Float(value) / 255
    return [component, component, component, 1]
  }
  let input = try PipelineImageInput(width: 28, height: 28, rgba: rgba)
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors())
  #expect(await engine.validate(linked.document).isValid)
  let output = try await engine.execute(linked.document,
    packageRootsByID: [linked.packageID: modelURL],
    invocation: .init(values: [PipelineInvocation.sourceImageKey: .image(input)]))
  guard case .plainText(let text) = output else {
    Issue.record("Image classifier did not produce text")
    return
  }
  #expect(text.text == "7")

  let png = sample.deletingPathExtension().appendingPathExtension("png")
  defer { try? FileManager.default.removeItem(at: png) }
  let provider = try #require(CGDataProvider(data: Data(grayscale) as CFData))
  let cgImage = try #require(CGImage(width: 28, height: 28,
    bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 28,
    space: CGColorSpaceCreateDeviceGray(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false,
    intent: .defaultIntent))
  let destination = try #require(CGImageDestinationCreateWithURL(
    png as CFURL, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, cgImage, nil)
  #expect(CGImageDestinationFinalize(destination))
  var fileWorkflow = linked.document
  let sourceIndex = try #require(fileWorkflow.nodes.firstIndex(where: {
    $0.kind.rawValue == "input.image"
  }))
  fileWorkflow.nodes[sourceIndex].parameters["sourceName"] = .string(png.lastPathComponent)
  let fileOutput = try await engine.execute(fileWorkflow,
    sourceMediaRoot: png.deletingLastPathComponent(),
    packageRootsByID: [linked.packageID: modelURL], invocation: .init())
  guard case .plainText(let fileText) = fileOutput else {
    Issue.record("Image file workflow did not produce text")
    return
  }
  #expect(fileText.text == "7")
}
