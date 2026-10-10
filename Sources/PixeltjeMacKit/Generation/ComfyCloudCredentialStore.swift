import Foundation
import Security

enum ComfyCloudCredentialStore {
  static let didChange = Notification.Name("PixeltjeMac.comfyCloudCredentialDidChange")
  private static let service = "org.pixeltje.mac.comfy-cloud"
  private static let account = "api-key"

  static func load() throws -> String? {
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
      let key = String(data: data, encoding: .utf8), !key.isEmpty
    else {
      throw CredentialError("Could not read the Comfy Cloud API key from Keychain (\(status)).")
    }
    return key
  }

  static func save(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw CredentialError("Enter a Comfy Cloud API key.") }
    let data = Data(key.utf8)
    let identity: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let status = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = identity
      item[kSecValueData] = data
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw CredentialError("Could not save the Comfy Cloud API key in Keychain (\(addStatus)).")
      }
    } else if status != errSecSuccess {
      throw CredentialError("Could not update the Comfy Cloud API key in Keychain (\(status)).")
    }
    NotificationCenter.default.post(name: didChange, object: nil)
  }

  static func remove() throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialError("Could not remove the Comfy Cloud API key from Keychain (\(status)).")
    }
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}

private struct CredentialError: LocalizedError {
  let message: String

  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
