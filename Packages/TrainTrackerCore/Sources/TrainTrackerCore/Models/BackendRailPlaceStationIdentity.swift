import Foundation

/// Decodes the backend's canonical station formats into each provider's namespace.
/// Transitous country is metadata; an old imported place can retain an incorrect country.
enum BackendRailPlaceStationIdentity {
    static func stationID(for identifier: RailIdentifier) -> RailIdentifier? {
        let value = identifier.rawValue
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard value.utf16.count <= 1_000, components.count == 4,
              components[0] == "rail", ["transitous", "srbijavoz"].contains(components[1]), components[2] == "station"
        else { return nil }
        let payload = String(components[3])
        guard !payload.isEmpty, payload.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), canonicalPayload(data) == payload,
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let fields = decoded.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count == 4, !fields[0].isEmpty, fields[0].utf16.count <= 500,
              fields[1].utf8.count == 2, fields[1].utf8.allSatisfy({ (65...90).contains($0) }),
              fields[2].isEmpty, fields[3].isEmpty else { return nil }
        if components[1] == "srbijavoz" {
            guard fields[1] == "RS" else { return nil }
            return RailIdentifier(region: "rs", source: "srbijavoz", nativeID: String(fields[0]))
        }
        return RailIdentifier(region: "eu", source: "transitous", nativeID: String(fields[0]))
    }

    private static func canonicalPayload(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
