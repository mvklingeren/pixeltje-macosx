import Foundation

/// Opt-in Metal source libraries. The resolved source is shared by validation,
/// execution, and shader cache identity. Only leading marker lines are read.
enum PipelineMetalLibraries {
  static func resolving(_ source: String) -> String {
    var markers = Set<String>()
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(2) {
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
      guard line == PipelineMetalEasing.marker || line == PipelineMetal3D.marker else {
        break
      }
      markers.insert(line)
    }
    var libraries: [String] = []
    if markers.contains(PipelineMetalEasing.marker) {
      libraries.append(PipelineMetalEasing.library)
    }
    if markers.contains(PipelineMetal3D.marker) {
      libraries.append(PipelineMetal3D.library)
    }
    return libraries.isEmpty ? source : libraries.joined(separator: "\n") + "\n" + source
  }
}
