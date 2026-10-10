import Foundation

/// Bundled, deterministic advice for resources whose installation benefits
/// from extra guidance. Entries are inert application data: matching never
/// probes the filesystem, opens a URL, or downloads a resource.
public struct PipelineResourceGuidanceCatalog: Sendable {
  public var entries: [PipelineResourceGuidanceEntry]

  public init(entries: [PipelineResourceGuidanceEntry] = []) {
    self.entries = entries
  }

  /// Returns at most one guide for a requirement. Ambiguous matches fail
  /// closed so an imported filename cannot select arbitrary advice.
  public func guide(
    for requirement: PipelineResourceRequirement
  ) -> PipelineResourceGuidanceEntry? {
    let matches = entries.filter { $0.matches(requirement) }
    guard matches.count == 1 else { return nil }
    return matches[0]
  }

  /// Returns each matching guide once, in stable catalog order.
  public func guides(
    for requirements: some Sequence<PipelineResourceRequirement>
  ) -> [PipelineResourceGuidanceEntry] {
    let matchingIDs = Set(requirements.compactMap { guide(for: $0)?.id })
    return entries.filter { matchingIDs.contains($0.id) }
  }
}

public struct PipelineResourceGuidanceEntry: Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var resourceKind: PipelineResourceKind
  public var componentRoles: Set<String>
  public var sourceNames: Set<String>
  public var sourceFormats: Set<String>
  public var acquisitionURL: URL
  public var cloneURL: URL?
  public var downloadMarkdown: String

  public init(
    id: String,
    displayName: String,
    resourceKind: PipelineResourceKind = .coreAIModel,
    componentRoles: Set<String>,
    sourceNames: Set<String>,
    sourceFormats: Set<String>,
    acquisitionURL: URL,
    cloneURL: URL? = nil,
    downloadMarkdown: String
  ) throws {
    guard Self.isHTTPS(acquisitionURL) else {
      throw PipelineResourceGuidanceError.nonHTTPSURL(acquisitionURL.absoluteString)
    }
    if let cloneURL, !Self.isHTTPS(cloneURL) {
      throw PipelineResourceGuidanceError.nonHTTPSURL(cloneURL.absoluteString)
    }
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !componentRoles.isEmpty,
      !sourceNames.isEmpty,
      !sourceFormats.isEmpty,
      !downloadMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PipelineResourceGuidanceError.incompleteEntry(id)
    }

    self.id = id
    self.displayName = displayName
    self.resourceKind = resourceKind
    self.componentRoles = componentRoles
    self.sourceNames = sourceNames
    self.sourceFormats = Set(sourceFormats.map(Self.normalizedToken))
    self.acquisitionURL = acquisitionURL
    self.cloneURL = cloneURL
    self.downloadMarkdown = downloadMarkdown
  }

  public var markdownDescription: String {
    [
      "<!-- pixeltje-resource-guide:\(id) -->",
      "## \(displayName)",
      downloadMarkdown,
    ]
    .joined(separator: "\n\n")
  }

  fileprivate func matches(_ requirement: PipelineResourceRequirement) -> Bool {
    guard resourceKind == requirement.kind,
      componentRoles.contains(requirement.componentRole),
      let sourceFormat = requirement.sourceFormat,
      sourceFormats.contains(Self.normalizedToken(sourceFormat))
    else { return false }

    let normalizedSource = Self.normalizedSourceName(requirement.sourceName)
    let basename = normalizedSource.split(separator: "/").last.map(String.init) ?? normalizedSource
    return sourceNames.contains { catalogName in
      let normalizedCatalogName = Self.normalizedSourceName(catalogName)
      return normalizedCatalogName.contains("/")
        ? normalizedCatalogName == normalizedSource
        : normalizedCatalogName == basename
    }
  }

  private static func normalizedSourceName(_ value: String) -> String {
    var normalized = value.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasPrefix("./") {
      normalized.removeFirst(2)
    }
    return normalized.lowercased()
  }

  private static func normalizedToken(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func isHTTPS(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host != nil
  }
}

public enum PipelineResourceGuidanceError: Error, Equatable, LocalizedError, Sendable {
  case incompleteEntry(String)
  case nonHTTPSURL(String)

  public var errorDescription: String? {
    switch self {
    case .incompleteEntry(let id):
      "Resource guidance entry \(id) is incomplete."
    case .nonHTTPSURL(let value):
      "Resource guidance URLs must use HTTPS: \(value)"
    }
  }
}

extension PipelineResourceGuidanceCatalog {
  public static let builtIn: PipelineResourceGuidanceCatalog = {
    do {
      let acquisitionURL = URL(
        string:
          "https://github.com/apple/coreai-models/tree/3f109efd54273391f9fd9f5f5b3d8c6e99836d55/models/flux2"
      )!
      let cloneURL = URL(
        string: "https://github.com/apple/coreai-models.git")!
      let hiDreamO1URL = URL(
        string: "https://huggingface.co/Comfy-Org/HiDream-O1-Image")!
      let qwenImageURL = URL(
        string: "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI")!
      let qwenImage21URL = URL(
        string: "https://huggingface.co/Comfy-Org/Qwen-Image-2.1")!
      return PipelineResourceGuidanceCatalog(entries: [
        try PipelineResourceGuidanceEntry(
          id: "public.coreai.flux2-klein-4b",
          displayName: "FLUX.2 Klein 4B for Core AI",
          componentRoles: ["denoiser"],
          sourceNames: [
            "diffusion_models/flux-2-klein-4b.safetensors",
            "flux-2-klein-4b.safetensors",
            "diffusion_models/flux-2-klein-base-4b.safetensors",
            "flux-2-klein-base-4b.safetensors",
          ],
          sourceFormats: ["safetensors"],
          acquisitionURL: acquisitionURL,
          cloneURL: cloneURL,
          downloadMarkdown: """
            This workflow uses FLUX.2 Klein 4B. Pixeltje requires Apple's current in-graph RoPE model ABI; the older public bundle with `rotary_emb_cos` and `rotary_emb_sin` inputs is not compatible.

            [View Apple's pinned FLUX.2 export recipe](\(acquisitionURL.absoluteString))

            Export the package outside Pixeltje, then link `exports/FLUX.2-klein-4B` in place:

            ```sh
            git clone \(cloneURL.absoluteString)
            cd coreai-models
            git checkout 3f109efd54273391f9fd9f5f5b3d8c6e99836d55
            uv run coreai.diffusion.export flux2-klein-4b --platform macOS
            ```

            The export downloads the original publisher weights and creates the multi-gigabyte Core AI package. Pixeltje does not run the export, download or copy the model, or hash its large weight files.

            The exported package contains the distilled Klein 4B transformer. It must not be silently substituted for a workflow's Base transformer.
            """),
        try PipelineResourceGuidanceEntry(
          id: "public.hidream-o1-image",
          displayName: "HiDream-O1 Image",
          componentRoles: ["denoiser"],
          sourceNames: [
            "checkpoints/hidream_o1_image_bf16.safetensors",
            "hidream_o1_image_bf16.safetensors",
            "checkpoints/hidream_o1_image_dev_fp8_scaled.safetensors",
            "hidream_o1_image_dev_fp8_scaled.safetensors",
          ],
          sourceFormats: ["safetensors"],
          acquisitionURL: hiDreamO1URL,
          downloadMarkdown: """
            This workflow uses HiDream-O1-Image, a VAE-less pixel-space transformer. The imported graph is structural: its nodes, ports, parameters and resource provenance are native, but Pixeltje has no Core AI package for this family yet.

            [View the publisher's ComfyUI checkpoints](\(hiDreamO1URL.absoluteString))

            Apple's Core AI model zoo currently publishes diffusion export recipes for Stable Diffusion and FLUX.2 only. Until an independently authored, offline HiDream-O1 export exists, run this workflow on a ComfyUI server; Pixeltje's pipeline engine cannot execute it.

            Pixeltje never downloads, converts, or hashes the original `.safetensors` weights.
            """),
        try PipelineResourceGuidanceEntry(
          id: "public.qwen-image",
          displayName: "Qwen-Image",
          componentRoles: ["denoiser"],
          sourceNames: [
            "diffusion_models/qwen_image_fp8_e4m3fn.safetensors",
            "qwen_image_fp8_e4m3fn.safetensors",
          ],
          sourceFormats: ["safetensors"],
          acquisitionURL: qwenImageURL,
          downloadMarkdown: """
            This workflow uses Qwen-Image. Every node in the published ComfyUI template maps one-for-one onto native Pixeltje nodes, so the imported graph carries its denoiser, text encoder, VAE, optional Lightning LoRA and sampling settings as typed state.

            [View the publisher's ComfyUI split files](\(qwenImageURL.absoluteString))

            The linked resources stay unresolved until a Core AI package for this family exists. Apple's model zoo publishes diffusion export recipes for Stable Diffusion and FLUX.2 only, so run this workflow on a ComfyUI server for now.

            Pixeltje never downloads, converts, or hashes the original `.safetensors` weights.
            """),
        try PipelineResourceGuidanceEntry(
          id: "public.qwen-image-2-1",
          displayName: "Qwen-Image 2.1",
          componentRoles: ["denoiser"],
          sourceNames: [
            "diffusion_models/qwen_image_2.1_int8_convrot.safetensors",
            "qwen_image_2.1_int8_convrot.safetensors",
          ],
          sourceFormats: ["safetensors"],
          acquisitionURL: qwenImage21URL,
          downloadMarkdown: """
            This workflow uses Qwen-Image 2.1, whose `TextEncodeQwenImage21` node produces positive conditioning, negative conditioning and a reference-sized latent from one text encoder pass.

            [View the publisher's ComfyUI files](\(qwenImage21URL.absoluteString))

            The imported graph is structural. No Core AI package exists for this family yet, so run the workflow on a ComfyUI server until an offline export recipe is available.

            Pixeltje never downloads, converts, or hashes the original `.safetensors` weights.
            """),
      ])
    } catch {
      preconditionFailure("Invalid built-in resource guidance catalog: \(error)")
    }
  }()
}
