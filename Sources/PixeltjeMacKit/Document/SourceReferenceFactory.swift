import CryptoKit
import Foundation
import PixeltjeMacDomain

enum SourceReferenceFactory {
  static func make(for url: URL) throws -> SourceReference {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let bookmark = try? url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    return SourceReference(
      originalFilename: url.lastPathComponent,
      linkedPath: url.path,
      securityScopedBookmark: bookmark,
      fingerprint: SourceFingerprint(
        byteLength: UInt64(values.fileSize ?? 0),
        modificationDate: values.contentModificationDate
      )
    )
  }

  static func sha256(of url: URL) throws -> String {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func resolve(_ source: SourceReference) throws -> URL {
    if let bookmark = source.securityScopedBookmark {
      var stale = false
      if let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ), !stale {
        return url
      }
    }
    if let path = source.linkedPath {
      return URL(fileURLWithPath: path)
    }
    throw PixeltjeMacError(
      "RAW source unavailable",
      "The project does not contain an embedded source or a usable linked source."
    )
  }

  static func validateQuickFingerprint(_ source: SourceReference, at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PixeltjeMacError(
        "RAW source missing",
        "The linked RAW source \(source.originalFilename) could not be found."
      )
    }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = UInt64(values.fileSize ?? 0)
    guard size == source.fingerprint.byteLength else {
      throw PixeltjeMacError(
        "RAW source changed",
        "The linked RAW source has a different byte length. Relink or explicitly accept the changed source before rendering."
      )
    }
  }
}
