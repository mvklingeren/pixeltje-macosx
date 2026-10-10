import Foundation

/// The RAW file to develop.
///
/// A project links to its RAW rather than carrying a copy, so rendering always
/// starts from a file on disk.
public enum RawInput: Equatable, Sendable {
  case file(URL)

  var displayName: String {
    switch self {
    case .file(let url): url.lastPathComponent
    }
  }
}

public enum RenderQuality: Equatable, Sendable {
  case proxy(maximumLongEdge: Int)
  case full

  var isProxy: Bool {
    if case .proxy = self { true } else { false }
  }
}
