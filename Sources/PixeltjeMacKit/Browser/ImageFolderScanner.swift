import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFolderScanner {
  static let cameraRawType = UTType("public.camera-raw-image")!
  private static let imageSourceTypes: [UTType] = {
    (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
  }()

  static func files(in root: URL, recursively: Bool) -> [BrowserFile] {
    let keys: Set<URLResourceKey> = [
      .contentModificationDateKey,
      .contentTypeKey,
      .fileSizeKey,
      .isRegularFileKey,
    ]
    var options: FileManager.DirectoryEnumerationOptions = [
      .skipsHiddenFiles,
      .skipsPackageDescendants,
    ]
    if !recursively {
      options.insert(.skipsSubdirectoryDescendants)
    }

    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: options
      )
    else { return [] }

    let rootPath = root.standardizedFileURL.path
    var result: [BrowserFile] = []
    for case let url as URL in enumerator {
      guard
        let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true,
        let kind = kind(for: values.contentType, pathExtension: url.pathExtension)
      else { continue }

      let path = url.standardizedFileURL.path
      let relativePath =
        path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1))
        : url.lastPathComponent
      result.append(
        BrowserFile(
          url: url,
          relativePath: relativePath,
          kind: kind,
          byteLength: UInt64(max(values.fileSize ?? 0, 0)),
          modificationDate: values.contentModificationDate
        ))
    }

    return result.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
  }

  static func kind(for contentType: UTType?, pathExtension: String) -> BrowserFileKind? {
    let extensionType = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
    let candidates = [contentType, extensionType].compactMap { $0 }
    if candidates.contains(where: { $0.conforms(to: cameraRawType) }) {
      return .cameraRaw
    }
    if candidates.contains(where: { $0.conforms(to: .image) }) {
      return .coreImage
    }
    if candidates.contains(where: { candidate in
      imageSourceTypes.contains(where: { candidate.conforms(to: $0) })
    }) {
      return .coreImage
    }
    return nil
  }
}
