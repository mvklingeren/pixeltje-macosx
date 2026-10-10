import Foundation
import PixeltjeMacDomain

/// Command-line inputs understood by the application executable.
///
/// A size is a one-launch override for a new untitled document. It never
/// changes the preference used by File > New on later launches.
public struct PixeltjeMacLaunchOptions: Equatable, Sendable {
  public let urls: [URL]
  public let newDocumentSize: CanvasRecipe?

  public init(urls: [URL] = [], newDocumentSize: CanvasRecipe? = nil) {
    self.urls = urls
    self.newDocumentSize = newDocumentSize
  }

  public static func parse(_ arguments: [String]) throws -> PixeltjeMacLaunchOptions {
    var urls: [URL] = []
    var size: CanvasRecipe?
    var index = arguments.startIndex
    var parsesOptions = true

    while index < arguments.endIndex {
      let argument = arguments[index]
      if parsesOptions, argument == "--" {
        parsesOptions = false
      } else if parsesOptions, argument == "--size" {
        guard size == nil else { throw PixeltjeMacLaunchOptionError.duplicateSize }
        index = arguments.index(after: index)
        guard index < arguments.endIndex else {
          throw PixeltjeMacLaunchOptionError.missingSize
        }
        size = try parseSize(arguments[index])
      } else if parsesOptions, argument.hasPrefix("--size=") {
        guard size == nil else { throw PixeltjeMacLaunchOptionError.duplicateSize }
        size = try parseSize(String(argument.dropFirst("--size=".count)))
      } else if parsesOptions, argument.hasPrefix("-") {
        throw PixeltjeMacLaunchOptionError.unknownOption(argument)
      } else {
        urls.append(
          URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
            .standardizedFileURL)
      }
      index = arguments.index(after: index)
    }

    guard size == nil || urls.isEmpty else {
      throw PixeltjeMacLaunchOptionError.sizeWithFiles
    }
    return PixeltjeMacLaunchOptions(urls: urls, newDocumentSize: size)
  }

  private static func parseSize(_ value: String) throws -> CanvasRecipe {
    let components = value.split(whereSeparator: { $0 == "x" || $0 == "X" || $0 == "×" })
    guard components.count == 2,
      let width = Int(components[0]),
      let height = Int(components[1]),
      width > 0,
      height > 0
    else {
      throw PixeltjeMacLaunchOptionError.invalidSize(value)
    }
    return CanvasRecipe(width: width, height: height)
  }
}

public enum PixeltjeMacLaunchOptionError: LocalizedError, Equatable, Sendable {
  case duplicateSize
  case invalidSize(String)
  case missingSize
  case sizeWithFiles
  case unknownOption(String)

  public var errorDescription: String? {
    switch self {
    case .duplicateSize:
      "Specify --size only once."
    case .invalidSize(let value):
      "Invalid canvas size '\(value)'. Use positive pixels in WIDTHxHEIGHT form."
    case .missingSize:
      "--size requires a value in WIDTHxHEIGHT form."
    case .sizeWithFiles:
      "--size creates a new document and cannot be combined with file or folder paths."
    case .unknownOption(let option):
      "Unknown option '\(option)'."
    }
  }
}
