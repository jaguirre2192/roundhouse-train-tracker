import Foundation
import Security

enum AccountSessionStore {
    private static let account = "app-session"
    private static var service: String { "\(Bundle.main.bundleIdentifier ?? "TrainTracker").account\(AccountBackendRouting.shared.storageSuffix)" }

    static func load() -> String? {
        let query: [String: Any] = baseQuery.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        delete()
        var input = baseQuery
        input[kSecValueData as String] = Data(token.utf8)
        input[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(input as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
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
