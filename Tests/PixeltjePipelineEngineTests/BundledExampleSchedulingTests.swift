import AppKit
import Foundation
import PixeltjePipelineBaseTestSetRuntime
import PixeltjePipelineDomain
@testable import PixeltjePipelineEngine
import PixeltjePipelineFLUX2Runtime
import PixeltjePipelineResourceLinking
import PixeltjePipelineSegmentationRuntime
import PixeltjePipelineSDXSRuntime
import PixeltjePipelineStableAudioRuntime
import PixeltjePipelineTextRuntime
import PixeltjePipelineTrainingRuntime
import Testing

@Test func bundledExamplesUseNativeNodeScheduling() async throws {
  var root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent()
  root.deleteLastPathComponent()
  root.deleteLastPathComponent()
  let examples = root.appendingPathComponent("Examples", isDirectory: true)
  let fluxRunner = FLUX2KleinPipelineRunner()
  let flux9BRunner = FLUX2Klein9BSplitRunner()
  let textRunner = CoreAITextPipelineRunner()
  let audioRunner = StableAudio3Runner()
  let sam31Runner = SAM31PipelineRunner()
  let trainingWorker = ModelTrainingWorker()
  let engine = PixeltjePipelineEngine(
    additionalNodeDescriptors: [
      FLUX2KleinPipelineFamily.makeCompositeNodeDescriptor(),
      FLUX2Klein9BSplitFamily.descriptor(),
      CoreAITextPipelineFamily.makeCompositeNodeDescriptor(),
      SAM31PipelineFamily.descriptor(),
      SDXSPipelineFamily.descriptor(),
      StableAudio3Family.descriptor(),
    ],
    additionalNodeExecutors: BaseTestSetPipelineFamily.makeNodeExecutors()
      + [PipelineNodeExecutor(kind: .zImageGenerate,
          validate: ZImageCompositeNode.diagnostics) { _, _, _ in
          throw PipelineEngineError.unsupportedPipeline("A Metal command queue is required.")
        },
        // This test validates scheduling without creating a GPU renderer.
        PipelineNodeExecutor(kind: .renderMetal) { _, _, _ in
          throw PipelineEngineError.unsupportedPipeline("A Metal command queue is required.")
        },
        PipelineNodeExecutor(kind: .gpuProgram) { _, _, _ in
          throw PipelineEngineError.unsupportedPipeline("A Metal command queue is required.")
        },
        PipelineNodeExecutor(kind: .coreAIImageClassifier) { _, _, _ in
          throw PipelineEngineError.unsupportedPipeline("A Metal command queue is required.")
        },
        FLUX2KleinPipelineFamily.makeNodeExecutor(runner: fluxRunner),
        FLUX2Klein9BSplitFamily.executor(runner: flux9BRunner),
        StableAudio3Family.executor(runner: audioRunner),
        CoreAITextPipelineFamily.makeNodeExecutor(runner: textRunner),
        SAM31PipelineFamily.executor(runner: sam31Runner),
        ModelTrainingRuntime.executor(worker: trainingWorker),
        PipelineNodeExecutor(kind: SDXSPipelineFamily.nodeKind) { _, _, _ in
          throw PipelineEngineError.unsupportedPipeline("A Metal command queue is required.")
        }])

  let enumerator = try #require(FileManager.default.enumerator(
    at: examples, includingPropertiesForKeys: nil))
  let files = enumerator.allObjects.compactMap { $0 as? URL }
    .filter { $0.lastPathComponent.hasSuffix(".pixpipeline.json") }
  #expect(!files.isEmpty)
  for file in files {
    let document = try PipelineJSON.decode(Data(contentsOf: file))
    #expect(document.requirements.familyABIs.isEmpty,
      "\(file.lastPathComponent) still selects a workflow-family adapter")
    let report = await engine.validate(document)
    switch file.lastPathComponent {
    case "image_flux2_klein_text_to_image_4b_base.pixpipeline.json":
      #expect(report.diagnostics.contains { $0.code == .unsupportedNodeImplementation })
    case "image_flux2_klein_text_to_image_9b_fp8_coreai.pixpipeline.json",
      "image_flux2_klein_text_to_image_9b_real_hd_2k_coreai.pixpipeline.json":
      #expect(!report.diagnostics.contains { $0.code == .unsupportedNodeImplementation })
      #expect(report.diagnostics.contains { $0.code == .unresolvedResource })
      #expect(report.errors.allSatisfy {
        $0.code == .unresolvedResource
      }, "\(file.lastPathComponent): \(report.diagnostics)")
    case "basic-coreai-text-completion.pixpipeline.json",
      "gemma-3-12b-instruct-coreai.pixpipeline.json",
      "z-image example workflow.pixpipeline.json":
      #expect(report.diagnostics.contains { $0.code == .unresolvedResource })
      #expect(report.errors.allSatisfy { $0.code == .unresolvedResource },
        "\(file.lastPathComponent): \(report.diagnostics)")
    default:
      #expect(report.isValid, "\(file.lastPathComponent): \(report.diagnostics)")
    }
  }
}

@Test func klein9BSplitLocalPackageExecutesWhenRequested() async throws {
  guard let directory = ProcessInfo.processInfo.environment["PIXELTJE_FLUX9B_SMOKE_PACKAGE"],
    !directory.isEmpty
  else { return }
  let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let variant = ProcessInfo.processInfo.environment["PIXELTJE_FLUX9B_SMOKE_VARIANT"]
  let filename = variant == "real-hd-2k"
    ? "image_flux2_klein_text_to_image_9b_real_hd_2k_coreai.pixpipeline.json"
    : "image_flux2_klein_text_to_image_9b_fp8_coreai.pixpipeline.json"
  let example = root.appendingPathComponent(
    "Examples/" + filename)
  let document = try PipelineJSON.decode(Data(contentsOf: example))
  let packageURL = URL(fileURLWithPath: directory, isDirectory: true)
  let linked = try PipelineCoreAIPackageRelinker.relinkNativeFlux9BSplit(
    in: document, toPackageAt: packageURL).document
  let engine = try PixeltjePipelineEngine.makeDefault(
    additionalNodeDescriptors: [FLUX2Klein9BSplitFamily.descriptor()],
    additionalNodeExecutors: [
      FLUX2Klein9BSplitFamily.executor(runner: FLUX2Klein9BSplitRunner())
    ])
  let report = await engine.validate(linked)
  #expect(report.isValid, "\(report.diagnostics)")
  let output = try await engine.execute(
    linked,
    packageRootsByID: [FLUX2Klein9BSplitFamily.packageID: packageURL],
    invocation: PipelineInvocation(values: [PipelineInvocation.promptKey:
      .string("A red fox in a snowy forest, detailed photograph")]))
  guard case .image(let image) = output else {
    Issue.record("Klein 9B did not return an image")
    return
  }
  #expect(image.width == 1024 && image.height == 1024)
  #expect(image.planarRGB.count == 3 * 1024 * 1024)
  let allFinite = image.planarRGB.allSatisfy { $0.isFinite }
  #expect(allFinite)
  let range = image.planarRGB.min()!...image.planarRGB.max()!
  #expect(range.upperBound - range.lowerBound > 0.1)
  if let outputPath = ProcessInfo.processInfo.environment["PIXELTJE_FLUX9B_SMOKE_OUTPUT"] {
    let pixels = 1024 * 1024
    var rgba = [UInt8](repeating: 255, count: pixels * 4)
    for pixel in 0..<pixels {
      for channel in 0..<3 {
        let value = image.planarRGB[channel * pixels + pixel]
        let normalized = min(max(image.encoding.normalizedSRGBComponent(from: value), 0), 1)
        rgba[pixel * 4 + channel] = UInt8((normalized * 255).rounded())
      }
    }
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let bitmap = try #require(CGImage(
      width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 1024 * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    let png = try #require(NSBitmapImageRep(cgImage: bitmap).representation(
      using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  }
}

@Test func klein9BExamplesKeepBaseAndFusedAdapterSeparate() async throws {
  var root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent()
  root.deleteLastPathComponent()
  root.deleteLastPathComponent()
  let examples = root.appendingPathComponent("Examples", isDirectory: true)
  let files = [
    "image_flux2_klein_text_to_image_9b_fp8_coreai.pixpipeline.json",
    "image_flux2_klein_text_to_image_9b_real_hd_2k_coreai.pixpipeline.json",
  ]
  let documents = try files.map { filename in
    try PipelineJSON.decode(Data(contentsOf: examples.appendingPathComponent(filename)))
  }
  let generationNodes = try documents.map { document in
    try #require(document.nodes.first { $0.id.rawValue == "generate" })
  }
  #expect(documents[0].id != documents[1].id)
  #expect(generationNodes.allSatisfy {
    $0.kind.rawValue == "coreai.flux2Klein9BSplitGenerate"
      && $0.parameters["width"]?.integerValue == 1024
      && $0.parameters["height"]?.integerValue == 1024
      && $0.resources.values.allSatisfy { $0.unresolvedRequirement != nil }
  })
  let base = generationNodes[0]
  let adapted = generationNodes[1]
  #expect(base.origin?.metadata["adapterFusion"] == .string("none"))
  #expect(adapted.origin?.metadata["adapterName"] == .string("HighDetail.safetensors"))
  #expect(adapted.origin?.metadata["adapterFusion"] == .string(
    "offline DoRA at strength 1.0"))
  #expect(adapted.origin?.metadata["adapterSHA256"] == .string(
    "108c649190f0953852feb15dad3d8ef8821753814a386ae46006d6949f722616"))
  #expect(base.resources["denoiser"]?.unresolvedRequirement?.sourceName
    == "FLUX.2-klein-9B-fp8-1024-experimental")
  #expect(adapted.resources["denoiser"]?.unresolvedRequirement?.sourceName
    == "FLUX.2-klein-9B-fp8-1024-real-hd-2k")
  #expect(base.resources["textEncoder"] == adapted.resources["textEncoder"])
  #expect(base.resources["vaeDecoder"] == adapted.resources["vaeDecoder"])
}
