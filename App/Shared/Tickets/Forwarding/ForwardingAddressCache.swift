import Foundation

/// Caches the last address locally per signed-in user so Settings can continue showing it during
/// a temporary network failure. Authenticated status reads normally re-derive the same address on
/// the backend. The address is not an app-session credential and is never shared with the Share
/// extension's App Group container, which has no need for it.
enum ForwardingAddressCache {
    private static func key(userID: String) -> String { "forwarding-address-\(userID)\(AccountBackendRouting.shared.storageSuffix)" }

    static func load(userID: String) -> String? {
        UserDefaults.standard.string(forKey: key(userID: userID))
    }

    static func save(_ address: String, userID: String) {
        UserDefaults.standard.set(address, forKey: key(userID: userID))
    }

    static func clear(userID: String) {
        UserDefaults.standard.removeObject(forKey: key(userID: userID))
    }
}
