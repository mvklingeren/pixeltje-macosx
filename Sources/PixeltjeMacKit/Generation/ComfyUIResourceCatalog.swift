import Foundation

struct ComfyUIRequiredModel: Hashable, Sendable {
  var relativePath: String

  var filename: String { String(relativePath.split(separator: "/").last ?? "") }
  var directory: String {
    String(relativePath.split(separator: "/", maxSplits: 1).first ?? "")
  }
  var selectedName: String {
    String(relativePath.split(separator: "/", maxSplits: 1).last ?? "")
  }
}

struct ComfyUIDownloadResource: Sendable {
  var relativePath: String
  var sizeLabel: String
}

enum ComfyUIResourceCatalog {
  private static let loaderInputs: [String: (input: String, directory: String)] = [
    "UNETLoader": ("unet_name", "diffusion_models"),
    "CLIPLoader": ("clip_name", "text_encoders"),
    "VAELoader": ("vae_name", "vae"),
    "UpscaleModelLoader": ("model_name", "upscale_models"),
    "CheckpointLoaderSimple": ("ckpt_name", "checkpoints"),
  ]

  /// Inspect the resolved request, since a user can choose a different model
  /// from the one stored in the bundled template.
  static func requiredModels(in workflow: Data) throws -> [ComfyUIRequiredModel] {
    guard let nodes = try JSONSerialization.jsonObject(with: workflow) as? [String: Any] else {
      throw PixeltjeMacError("Workflow invalid", "The resolved workflow is not a JSON object.")
    }
    var requirements = Set<ComfyUIRequiredModel>()
    for value in nodes.values {
      guard let node = value as? [String: Any],
        let classType = node["class_type"] as? String,
        let loader = loaderInputs[classType],
        let inputs = node["inputs"] as? [String: Any],
        let selected = inputs[loader.input] as? String,
        !selected.isEmpty
      else { continue }
      requirements.insert(ComfyUIRequiredModel(
        relativePath: "\(loader.directory)/\(selected)"))
    }
    return requirements.sorted { $0.relativePath < $1.relativePath }
  }

  /// Only resource entries named by this workflow's script can be offered in
  /// the app. A custom model selection should not launch a default downloader.
  static func downloadableResources(templateID: String) throws -> [String: ComfyUIDownloadResource] {
    let resourceIDs = try lines(named: "workflow-resources")
      .compactMap { line -> String? in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == templateID else { return nil }
        return String(fields[1])
      }
    guard !resourceIDs.isEmpty else {
      throw PixeltjeMacError("Download unavailable", "This workflow has no download script.")
    }
    let selectedIDs = Set(resourceIDs)
    var result: [String: ComfyUIDownloadResource] = [:]
    for line in try lines(named: "resources") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 6, selectedIDs.contains(String(fields[0])) else { continue }
      let path = String(fields[1])
      result[path] = ComfyUIDownloadResource(
        relativePath: path, sizeLabel: String(fields[2]))
    }
    return result
  }

  private static func lines(named name: String) throws -> [String] {
    guard let url = ComfyUIWorkflowCatalog.workflowBundle.url(
      forResource: name, withExtension: "tsv", subdirectory: "ComfyUI")
    else {
      throw PixeltjeMacError("Download unavailable", "The bundled resource list is missing.")
    }
    return try String(contentsOf: url, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
  }
}
