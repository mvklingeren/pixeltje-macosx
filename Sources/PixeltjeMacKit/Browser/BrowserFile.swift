import Foundation

enum BrowserFileKind: Equatable, Sendable {
  case cameraRaw
  case coreImage
}

struct BrowserFile: Hashable, Sendable {
  let url: URL
  let relativePath: String
  var kind: BrowserFileKind
  let byteLength: UInt64
  let modificationDate: Date?

  var displayName: String { url.lastPathComponent }

  func cacheKey(maximumPixelSize: Int) -> String {
    let dateBits = modificationDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0
    return "\(url.standardizedFileURL.path)|\(byteLength)|\(dateBits)|\(maximumPixelSize)"
  }
}
