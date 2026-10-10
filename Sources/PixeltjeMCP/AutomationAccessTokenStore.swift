import Foundation
import Security

public enum AutomationAccessTokenStore {
  private static let service = "org.pixeltje.mac.automation"
  private static let account = "local-mcp-bearer-token"

  /// Returns the per-install bearer token, creating it in the user's Keychain
  /// on first use. It is never persisted in project files or UserDefaults.
  public static func loadOrCreate() throws -> String {
    if let existing = try load() { return existing }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw TokenStoreError("Secure random token generation failed.")
    }
    let token = Data(bytes).base64EncodedString()
    let data = Data(token.utf8)
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData: data,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem, let existing = try load() { return existing }
    guard status == errSecSuccess else {
      throw TokenStoreError("Keychain could not store the automation token (\(status)).")
    }
    return token
  }

  /// Revokes the current credential and returns a fresh one.
  public static func rotate() throws -> String {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TokenStoreError("Keychain could not revoke the automation token (\(status)).")
    }
    return try loadOrCreate()
  }

  private static func load() throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let token = String(data: data, encoding: .utf8), !token.isEmpty
    else {
      throw TokenStoreError("Keychain could not read the automation token (\(status)).")
    }
    return token
  }
}

private struct TokenStoreError: LocalizedError {
  var message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}
