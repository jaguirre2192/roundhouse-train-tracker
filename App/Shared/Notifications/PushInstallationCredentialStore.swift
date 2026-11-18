import Foundation
import Security

enum PushInstallationCredentialStore {
  private static let account = "push-installation-credential"
  private static var service: String {
    "\(Bundle.main.bundleIdentifier ?? "TrainTracker").push"
  }

  static func loadOrCreate() throws -> String {
    if let existing = load() { return existing }
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
    let credential = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try save(credential)
  }

  private static func load() -> String? {
    let query = baseQuery.merging([
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]) { _, new in new }
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8),
      value.count == 43
    else { return nil }
    return value
  }

  private static func save(_ credential: String) throws -> String {
    var input = baseQuery
    input[kSecValueData as String] = Data(credential.utf8)
    input[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(input as CFDictionary, nil)
    // Another client may have won insertion. Always use the credential actually saved.
    if status == errSecDuplicateItem, let existing = load() { return existing }
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
    return credential
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  enum StoreError: Error { case keychain(OSStatus) }
}
