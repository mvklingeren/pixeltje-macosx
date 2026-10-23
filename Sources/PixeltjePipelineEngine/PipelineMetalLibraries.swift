import Foundation

/// Opt-in Metal source libraries. The resolved source is shared by validation,
/// execution, and shader cache identity. Only leading marker lines are read.
enum PipelineMetalLibraries {
  private static let available = [
    (PipelineMetalEasing.marker, PipelineMetalEasing.library),
    (PipelineMetal3D.marker, PipelineMetal3D.library),
    (PipelineMetalTerrain.marker, PipelineMetalTerrain.library),
    (PipelineMetalPostFX.marker, PipelineMetalPostFX.library),
    (PipelineMetalPhysics.marker, PipelineMetalPhysics.library),
  ]

  static func resolving(_ source: String) -> String {
    var markers = Set<String>()
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false)
      .prefix(available.count) {
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
      guard available.contains(where: { $0.0 == line }) else { break }
      markers.insert(line)
    }
    let libraries = available.filter { markers.contains($0.0) }.map(\.1)
    return libraries.isEmpty ? source : libraries.joined(separator: "\n") + "\n" + source
  }
}
