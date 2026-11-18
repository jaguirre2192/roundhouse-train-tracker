import Foundation

enum TrainTrackerBackendConfiguration {
    static let canonicalHost = "api.gettraintracker.com"

    private static let trustedCallbackHosts: Set<String> = [
        canonicalHost,
        "legacy-roundhouse.example.invalid",
    ]

    static var baseURL: URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "TrainTrackerAPIBaseURL") as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : URL(string: value)
    }

    /// APNs environment for both train alerts and Live Activities. Info.plist carries the
    /// per-configuration build setting so a token is never enrolled for the wrong gateway.
    static var apnsEnvironment: String {
        apnsEnvironment(infoPlistValue: Bundle.main.object(forInfoDictionaryKey: "TrainTrackerAPNSEnvironment"))
    }

    static func apnsEnvironment(infoPlistValue: Any?) -> String {
        let value = (infoPlistValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, ["sandbox", "production"].contains(value) { return value }
        // Only a build missing the setting reaches here; distributed builds use production.
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static func isTrustedCallback(_ url: URL, path: String) -> Bool {
        url.scheme == "https"
            && url.path == path
            && url.host.map { trustedCallbackHosts.contains($0) || AccountBackendRouting.shared.isSelectedSandboxHost($0) } == true
    }
}
