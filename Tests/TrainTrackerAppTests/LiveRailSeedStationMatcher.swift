import Foundation
import TrainTrackerCore

/// Live seeds name an exact station. Provider formatting may vary, but station words,
/// country, and a unique result remain required before the test discovers a service.
enum LiveRailSeedStationMatcher {
    static func uniqueMatch(in places: [RailPlace], seed: LiveRailSeed.Station) -> RailPlace? {
        let expected = normalizedWords(seed.name)
        guard !expected.isEmpty else { return nil }
        let matches = places.filter {
            $0.kind == .station && $0.countryCode == seed.country
                && normalizedWords($0.displayName) == expected
                && matchesNativeID($0, seed: seed)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func matchesNativeID(_ place: RailPlace, seed: LiveRailSeed.Station) -> Bool {
        guard let nativeID = seed.nativeID else { return true }
        // Match the backend's canonical station ID; no provider ordering or proximity fallback.
        let payload = Data([nativeID, seed.country, "", ""].joined(separator: "\u{1f}").utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return place.id.rawValue == "rail:transitous:station:\(payload)"
    }

    private static func normalizedWords(_ name: String) -> String {
        var words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        // The feed alternates between the German main-station label and its abbreviation.
        // Expand this exact final token only; the rest of the station name must still match.
        if words.last == "hbf" { words[words.count - 1] = "hauptbahnhof" }
        return words.joined(separator: " ")
    }
}
