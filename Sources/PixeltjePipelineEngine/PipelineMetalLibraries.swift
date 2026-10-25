import Foundation

/// Opt-in Metal source libraries. The resolved source is shared by validation,
/// execution, and shader cache identity. Leading marker lines and `#line`
/// directives are read so file-expanded shaders still match their markers.
enum PipelineMetalLibraries {
  static func lineDirective(_ line: Int, fileName: String) -> String {
    var escaped = ""
    for scalar in fileName.unicodeScalars {
      switch scalar.value {
      case 34: escaped += "\\\""
      case 92: escaped += "\\\\"
      case 0...31, 127: escaped += String(format: "\\%03o", scalar.value)
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return "#line \(line) \"\(escaped)\""
  }

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
      .prefix(available.count + 4) {
      let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
      if line.hasPrefix("#line ") { continue }
      guard available.contains(where: { $0.0 == line }) else { break }
      markers.insert(line)
    }
    let libraries = available.filter { markers.contains($0.0) }.map(\.1)
    guard !libraries.isEmpty else { return source }
    return libraries.joined(separator: "\n") + "\n#line 1\n" + source
  }
}
