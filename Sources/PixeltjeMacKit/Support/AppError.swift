import Foundation

public struct PixeltjeMacError: LocalizedError, Sendable {
  public let title: String
  public let message: String

  public init(_ title: String, _ message: String) {
    self.title = title
    self.message = message
  }

  public var errorDescription: String? { message }
}

extension Error {
  var userFacingMessage: String {
    (self as? LocalizedError)?.errorDescription ?? localizedDescription
  }
}
