// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "PixeltjeMacApp",
  platforms: [.macOS(.v27)],
  products: [
    .library(name: "PixeltjePipelineDomain", targets: ["PixeltjePipelineDomain"]),
    .library(name: "PixeltjeModelDesign", targets: ["PixeltjeModelDesign"]),
    .library(name: "PixeltjePipelineTrainingRuntime", targets: ["PixeltjePipelineTrainingRuntime"]),
    .executable(name: "pixeltje-model-export", targets: ["PixeltjeModelDesignCLI"]),
    .library(name: "PixeltjePipelineEngine", targets: ["PixeltjePipelineEngine"]),
    .library(
      name: "PixeltjePipelineComfyUIConverter",
      targets: ["PixeltjePipelineComfyUIConverter"]),
    .library(
      name: "PixeltjePipelineResourceLinking",
      targets: ["PixeltjePipelineResourceLinking"]),
    .library(
      name: "PixeltjePipelineFLUX2Runtime",
      targets: ["PixeltjePipelineFLUX2Runtime"]),
    .library(
      name: "PixeltjePipelineSDXSRuntime",
      targets: ["PixeltjePipelineSDXSRuntime"]),
    .library(
      name: "PixeltjePipelineStableAudioRuntime",
      targets: ["PixeltjePipelineStableAudioRuntime"]),
    .executable(
      name: "pixeltje-pipeline-benchmark-sdxs",
      targets: ["PixeltjePipelineSDXSBenchmark"]),
    .library(
      name: "PixeltjePipelineTextRuntime",
      targets: ["PixeltjePipelineTextRuntime"]),
    .library(
      name: "PixeltjePipelineBaseTestSetRuntime",
      targets: ["PixeltjePipelineBaseTestSetRuntime"]),
    .library(
      name: "PixeltjePipelineSegmentationRuntime",
      targets: ["PixeltjePipelineSegmentationRuntime"]),
    .executable(
      name: "pixeltje-pipeline-convert",
      targets: ["PixeltjePipelineConverterCLI"]),
    .executable(
      name: "pixeltje-pipeline-link-text",
      targets: ["PixeltjePipelineTextLinkCLI"]),
    .executable(
      name: "pixeltje-pipeline-run-text-loop",
      targets: ["PixeltjePipelineTextLoopCLI"]),
    .executable(name: "PixeltjePipeline", targets: ["PixeltjePipelineEditor"]),
    .executable(name: "pixeltje-pipeline-agent", targets: ["PixeltjePipelineAgent"]),
    .executable(name: "pixeltje-pipeline-benchmark", targets: ["PixeltjePipelineBenchmark"]),
    .executable(name: "pixeltje-pipeline-relink-flux2", targets: ["PixeltjePipelineRelinkFLUX2CLI"]),
    .executable(name: "pixeltje-pipeline-run", targets: ["PixeltjePipelineBaseTestSetCLI"]),
    .executable(name: "pixeltje-pipeline-run-base-test-set", targets: ["PixeltjePipelineBaseTestSetCLI"]),
    .executable(name: "pixeltje-pipeline-run-sam31", targets: ["PixeltjePipelineSAM31CLI"]),
    .executable(name: "pixeltje-pipeline-run-stable-audio-3", targets: ["PixeltjePipelineStableAudioCLI"]),
    .executable(name: "PixeltjeMacApp", targets: ["PixeltjeMacApp"]),
  ],
  dependencies: [
    // Tokenizer-only use. Learned-model execution remains exclusively Core AI.
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.3"),
    // Shared by the standalone Pipeline editor and ACP agent.
    .package(
      url: "https://github.com/apple/coreai-models.git",
      revision: "3f109efd54273391f9fd9f5f5b3d8c6e99836d55"),
  ],
  targets: [
    .target(
      name: "PixeltjeModelDesign",
      dependencies: ["PixeltjePipelineDomain"],
      path: "Sources/PixeltjeModelDesign",
      linkerSettings: [.linkedFramework("CryptoKit")]
    ),
    .executableTarget(
      name: "PixeltjeModelDesignCLI",
      dependencies: ["PixeltjeModelDesign", "PixeltjePipelineDomain"],
      path: "Sources/PixeltjeModelDesignCLI"
    ),
    .target(
      name: "PixeltjePipelineDomain",
      path: "Sources/PixeltjePipelineDomain",
      linkerSettings: [.linkedFramework("CryptoKit")]
    ),
    .target(
      name: "PixeltjePipelineEngine",
      dependencies: [
        "PixeltjeMacDomain", "PixeltjePipelineDomain", "PixeltjeModelDesign",
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      path: "Sources/PixeltjePipelineEngine",
      linkerSettings: [
        .linkedFramework("CoreAI"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("Metal"),
      ]
    ),
    .target(
      name: "PixeltjePipelineTrainingRuntime",
      dependencies: ["PixeltjeModelDesign", "PixeltjePipelineEngine", "PixeltjePipelineDomain"],
      path: "Sources/PixeltjePipelineTrainingRuntime"
    ),
    .target(
      name: "PixeltjePipelineComfyUIConverter",
      dependencies: ["PixeltjePipelineDomain"],
      path: "Sources/PixeltjePipelineComfyUIConverter"
    ),
    .target(
      name: "PixeltjePipelineResourceLinking",
      dependencies: ["PixeltjePipelineDomain"],
      path: "Sources/PixeltjePipelineResourceLinking",
      linkerSettings: [.linkedFramework("CryptoKit")]
    ),
    .target(
      name: "PixeltjePipelineFLUX2Runtime",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine", "PixeltjePipelineResourceLinking",
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "CoreAIDiffusion", package: "coreai-models"),
      ],
      path: "Sources/PixeltjePipelineFLUX2Runtime",
      linkerSettings: [
        .linkedFramework("CoreAI"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("Metal"),
      ]
    ),
    .target(
      name: "PixeltjePipelineSDXSRuntime",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineResourceLinking",
        .product(name: "CoreAIDiffusion", package: "coreai-models"),
      ],
      path: "Sources/PixeltjePipelineSDXSRuntime",
      linkerSettings: [.linkedFramework("CoreAI")]
    ),
    .target(
      name: "PixeltjePipelineStableAudioRuntime",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineResourceLinking",
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "CoreAIDiffusion", package: "coreai-models"),
      ],
      path: "Sources/PixeltjePipelineStableAudioRuntime",
      linkerSettings: [.linkedFramework("CoreAI")]
    ),
    .executableTarget(
      name: "PixeltjePipelineStableAudioCLI",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineBaseTestSetRuntime", "PixeltjePipelineStableAudioRuntime",
      ],
      path: "Sources/PixeltjePipelineStableAudioCLI"
    ),
    .executableTarget(
      name: "PixeltjePipelineSDXSBenchmark",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineResourceLinking", "PixeltjePipelineSDXSRuntime",
        "PixeltjePipelineTextRuntime", "PixeltjePipelineBaseTestSetRuntime",
      ],
      path: "Sources/PixeltjePipelineSDXSBenchmark",
      linkerSettings: [
        .linkedFramework("CoreGraphics"), .linkedFramework("ImageIO"),
      ]
    ),
    .target(
      name: "PixeltjePipelineTextRuntime",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        .product(name: "CoreAILM", package: "coreai-models"),
      ],
      path: "Sources/PixeltjePipelineTextRuntime",
      linkerSettings: [
        .linkedFramework("CoreAI"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("FoundationModels"),
      ]
    ),
    .executableTarget(
      name: "PixeltjePipelineTextLoopCLI",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineTextRuntime",
      ],
      path: "Sources/PixeltjePipelineTextLoopCLI"
    ),
    .target(
      name: "PixeltjePipelineBaseTestSetRuntime",
      dependencies: ["PixeltjePipelineDomain", "PixeltjePipelineEngine"],
      path: "Sources/PixeltjePipelineBaseTestSetRuntime",
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreImage"),
        .linkedFramework("ImageIO"),
      ]
    ),
    .target(
      name: "PixeltjePipelineSegmentationRuntime",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        .product(name: "CoreAISegmentation", package: "coreai-models"),
      ],
      path: "Sources/PixeltjePipelineSegmentationRuntime",
      linkerSettings: [
        .linkedFramework("CoreAI"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CryptoKit"),
      ]
    ),
    .target(
      name: "PixeltjeMacDomain",
      path: "Sources/PixeltjeMacDomain",
      linkerSettings: [.linkedFramework("CoreGraphics")]
    ),
    .target(
      name: "PixeltjeAutomation",
      dependencies: ["PixeltjeMacDomain"],
      path: "Sources/PixeltjeAutomation"
    ),
    .target(
      name: "PixeltjeScripting",
      dependencies: ["PixeltjeAutomation"],
      path: "Sources/PixeltjeScripting",
      linkerSettings: [.linkedFramework("JavaScriptCore")]
    ),
    .target(
      name: "PixeltjeMCP",
      dependencies: ["PixeltjeAutomation"],
      path: "Sources/PixeltjeMCP",
      linkerSettings: [
        .linkedFramework("Network"),
        .linkedFramework("Security"),
      ]
    ),
    .target(
      name: "PixeltjeMacKit",
      dependencies: [
        "PixeltjeMacDomain", "PixeltjeAutomation", "PixeltjeMCP", "PixeltjeScripting",
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      path: "Sources/PixeltjeMacKit",
      resources: [.copy("Resources/ComfyUI")],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Combine"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreImage"),
        .linkedFramework("CoreAI"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("FoundationModels"),
        .linkedFramework("ImageIO"),
        .linkedFramework("IOSurface"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("SwiftUI"),
        .linkedFramework("UniformTypeIdentifiers"),
        // Subject and person mask generators.
        .linkedFramework("Vision"),
      ]
    ),
    .executableTarget(
      name: "PixeltjePipelineEditor",
      dependencies: [
        "PixeltjeModelDesign", "PixeltjePipelineTrainingRuntime",
        "PixeltjePipelineComfyUIConverter", "PixeltjePipelineDomain",
        "PixeltjePipelineEngine", "PixeltjePipelineFLUX2Runtime",
        "PixeltjePipelineSDXSRuntime",
        "PixeltjePipelineStableAudioRuntime",
        "PixeltjePipelineTextRuntime", "PixeltjePipelineBaseTestSetRuntime",
        "PixeltjePipelineSegmentationRuntime",
        "PixeltjePipelineResourceLinking",
      ],
      path: "Sources/PixeltjePipelineEditor",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AVKit"),
        .linkedFramework("Combine"),
        .linkedFramework("SwiftUI"),
        .linkedFramework("UniformTypeIdentifiers"),
      ]
    ),
    .executableTarget(
      name: "PixeltjePipelineSAM31CLI",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineBaseTestSetRuntime", "PixeltjePipelineSegmentationRuntime",
      ],
      path: "Sources/PixeltjePipelineSAM31CLI",
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
    .executableTarget(
      name: "PixeltjePipelineAgent",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineFLUX2Runtime", "PixeltjePipelineSDXSRuntime",
        "PixeltjePipelineStableAudioRuntime",
        "PixeltjePipelineTextRuntime",
        "PixeltjePipelineBaseTestSetRuntime",
      ],
      path: "Sources/PixeltjePipelineAgent",
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
    .executableTarget(
      name: "PixeltjePipelineBenchmark",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine", "PixeltjePipelineFLUX2Runtime",
      ],
      path: "Sources/PixeltjePipelineBenchmark",
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
    .executableTarget(
      name: "PixeltjePipelineRelinkFLUX2CLI",
      dependencies: ["PixeltjePipelineDomain", "PixeltjePipelineResourceLinking"],
      path: "Sources/PixeltjePipelineRelinkFLUX2CLI"
    ),
    .executableTarget(
      name: "PixeltjePipelineConverterCLI",
      dependencies: [
        "PixeltjePipelineComfyUIConverter", "PixeltjePipelineDomain",
        "PixeltjePipelineResourceLinking",
        "PixeltjePipelineEngine",
      ],
      path: "Sources/PixeltjePipelineConverterCLI"
    ),
    .executableTarget(
      name: "PixeltjePipelineTextLinkCLI",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineTextRuntime", "PixeltjePipelineSDXSRuntime",
        "PixeltjePipelineSegmentationRuntime",
      ],
      path: "Sources/PixeltjePipelineTextLinkCLI",
      linkerSettings: [.linkedFramework("CoreAI")]
    ),
    .executableTarget(
      name: "PixeltjePipelineBaseTestSetCLI",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineBaseTestSetRuntime",
      ],
      path: "Sources/PixeltjePipelineBaseTestSetCLI",
      linkerSettings: [
        .linkedFramework("ImageIO"),
      ]
    ),
    .executableTarget(
      name: "PixeltjeMacApp",
      dependencies: ["PixeltjeMacKit"],
      path: "Sources/PixeltjeMacApp",
      resources: [.copy("Resources/AppIcon.icns")]
    ),
    .testTarget(
      name: "PixeltjeModelDesignTests",
      dependencies: ["PixeltjeModelDesign"],
      path: "Tests/PixeltjeModelDesignTests"
    ),
    .testTarget(
      name: "PixeltjePipelineTrainingRuntimeTests",
      dependencies: ["PixeltjePipelineTrainingRuntime", "PixeltjeModelDesign",
        "PixeltjePipelineDomain", "PixeltjePipelineEngine"],
      path: "Tests/PixeltjePipelineTrainingRuntimeTests"
    ),
    .testTarget(
      name: "PixeltjePipelineDomainTests",
      dependencies: ["PixeltjePipelineDomain"],
      path: "Tests/PixeltjePipelineDomainTests"
    ),
    .testTarget(
      name: "PixeltjePipelineEngineTests",
      dependencies: [
        "PixeltjePipelineComfyUIConverter", "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineBaseTestSetRuntime", "PixeltjePipelineFLUX2Runtime",
        "PixeltjePipelineStableAudioRuntime",
        "PixeltjePipelineResourceLinking", "PixeltjePipelineSegmentationRuntime",
        "PixeltjePipelineSDXSRuntime", "PixeltjePipelineTextRuntime",
        "PixeltjePipelineTrainingRuntime",
      ],
      path: "Tests/PixeltjePipelineEngineTests"
    ),
    .testTarget(
      name: "PixeltjePipelineEditorTests",
      dependencies: ["PixeltjePipelineEditor"],
      path: "Tests/PixeltjePipelineEditorTests"
    ),
    .testTarget(
      name: "PixeltjePipelineComfyUIConverterTests",
      dependencies: ["PixeltjePipelineComfyUIConverter", "PixeltjePipelineDomain"],
      path: "Tests/PixeltjePipelineComfyUIConverterTests"
    ),
    .testTarget(
      name: "PixeltjePipelineResourceLinkingTests",
      dependencies: ["PixeltjePipelineDomain", "PixeltjePipelineResourceLinking"],
      path: "Tests/PixeltjePipelineResourceLinkingTests"
    ),
    .testTarget(
      name: "PixeltjePipelineFLUX2RuntimeTests",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine", "PixeltjePipelineFLUX2Runtime",
      ],
      path: "Tests/PixeltjePipelineFLUX2RuntimeTests"
    ),
    .testTarget(
      name: "PixeltjePipelineTextRuntimeTests",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine", "PixeltjePipelineTextRuntime",
      ],
      path: "Tests/PixeltjePipelineTextRuntimeTests"
    ),
    .testTarget(
      name: "PixeltjePipelineBaseTestSetRuntimeTests",
      dependencies: [
        "PixeltjePipelineDomain", "PixeltjePipelineEngine",
        "PixeltjePipelineBaseTestSetRuntime",
      ],
      path: "Tests/PixeltjePipelineBaseTestSetRuntimeTests"
    ),
    .testTarget(
      name: "PixeltjeMacDomainTests",
      dependencies: ["PixeltjeMacDomain"],
      path: "Tests/PixeltjeMacDomainTests"
    ),
    .testTarget(
      name: "PixeltjeAutomationTests",
      dependencies: ["PixeltjeAutomation", "PixeltjeMacDomain"],
      path: "Tests/PixeltjeAutomationTests"
    ),
    .testTarget(
      name: "PixeltjeMCPTests",
      dependencies: ["PixeltjeAutomation", "PixeltjeMCP"],
      path: "Tests/PixeltjeMCPTests"
    ),
    .testTarget(
      name: "PixeltjeScriptingTests",
      dependencies: ["PixeltjeAutomation", "PixeltjeScripting"],
      path: "Tests/PixeltjeScriptingTests"
    ),
    .testTarget(
      name: "PixeltjeMacKitTests",
      dependencies: [
        "PixeltjeAutomation", "PixeltjeMacDomain", "PixeltjeMacKit", "PixeltjePipelineEngine",
        "PixeltjeScripting",
      ],
      path: "Tests/PixeltjeMacKitTests"
    ),
  ]
)
