import CryptoKit
import Foundation
import Security

enum OAuthFlow: String, Codable {
    case accountGoogle = "account-google"
    case gmail
}

struct OAuthHandoff: Codable, Sendable {
    let transactionID: String
    let verifier: String
    let expiresAt: Date

    var challenge: String { OAuthHandoffStore.digest(verifier) }
}

enum OAuthHandoffStore {
    static func create(for flow: OAuthFlow) throws -> OAuthHandoff {
        let value = OAuthHandoff(
            transactionID: "\(UUID().uuidString)-\(UUID().uuidString)",
            verifier: try randomValue(byteCount: 48),
            expiresAt: Date().addingTimeInterval(10 * 60)
        )
        try save(value, for: flow)
        return value
    }

    static func load(for flow: OAuthFlow) -> OAuthHandoff? {
        let query = baseQuery(for: flow).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = try? JSONDecoder().decode(OAuthHandoff.self, from: data),
              value.expiresAt > Date() else {
            delete(for: flow)
            return nil
        }
        return value
    }

    static func delete(for flow: OAuthFlow) {
        SecItemDelete(baseQuery(for: flow) as CFDictionary)
    }

    static func digest(_ value: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(value.utf8))))
    }

    static func randomValue(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return base64URL(Data(bytes))
    }

    private static func save(_ value: OAuthHandoff, for flow: OAuthFlow) throws {
        delete(for: flow)
        var input = baseQuery(for: flow)
        input[kSecValueData as String] = try JSONEncoder().encode(value)
        input[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(input as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func baseQuery(for flow: OAuthFlow) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "TrainTracker").oauth\(AccountBackendRouting.shared.storageSuffix)",
            kSecAttrAccount as String: flow.rawValue,
        ]
    }

    enum StoreError: Error { case keychain(OSStatus) }
}
