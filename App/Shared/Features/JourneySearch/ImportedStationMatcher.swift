import Foundation
import TrainTrackerCore

enum ImportedStationMatcher {
    static func bestPlace(named name: String, from candidates: [RailPlace]) -> RailPlace? {
        let query = QualifiedName(name)
        guard !query.name.isEmpty else { return nil }

        if let alias = ImportedStationAlias.matching(query.aliasNames) {
            // A known spelling names a particular station, never the first city
            // returned by a provider. Candidate spelling and country must both agree.
            for stationName in alias.stationNames {
                if let match = candidates.first(where: {
                    $0.kind == .station && $0.countryCode.uppercased() == alias.countryCode
                        && (alias.timeZoneIdentifier == nil || $0.timeZoneIdentifier == alias.timeZoneIdentifier)
                        && QualifiedName($0.displayName).name == stationName
                        && query.qualifiersMatch($0, additional: alias.qualifiers)
                }) {
                    return match
                }
            }
            return nil
        }

        let qualified = candidates.filter { query.qualifiersMatch($0) }
        let exact = qualified.filter { QualifiedName($0.displayName).name == query.name }
        if !exact.isEmpty {
            return unambiguousPlace(exact)
        }

        // Preserve specific partial station names such as "London St Pancras".
        // A single city word or a station that is only a fragment of the import
        // is not enough evidence to choose an endpoint automatically.
        guard query.name.split(separator: " ").count >= 2 else { return nil }
        let partial = qualified.filter {
            $0.kind == .station
                && containsPhrase(QualifiedName($0.displayName).name, query.name)
        }
        return unambiguousPlace(partial)
    }

    static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: english)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0 == "hauptbahnhof" ? "hbf" : String($0) }
            .joined(separator: " ")
    }

    private static let english = Locale(identifier: "en_US_POSIX")

    private static func unambiguousPlace(_ candidates: [RailPlace]) -> RailPlace? {
        let stations = candidates.filter { $0.kind == .station }
        let preferred = stations.isEmpty ? candidates : stations
        guard let first = preferred.first,
              preferred.allSatisfy({
                  $0.countryCode == first.countryCode
                      && $0.timeZoneIdentifier == first.timeZoneIdentifier
                      && abs($0.location.latitude - first.location.latitude) < 0.05
                      && abs($0.location.longitude - first.location.longitude) < 0.05
                      && QualifiedName($0.displayName).name == QualifiedName(first.displayName).name
              }) else { return nil }
        return first
    }

    private static func containsPhrase(_ value: String, _ phrase: String) -> Bool {
        (" " + value + " ").contains(" " + phrase + " ")
    }

    private struct QualifiedName {
        let name: String
        let qualifiers: [String]

        var aliasNames: [String] {
            (0...qualifiers.count).map { ([name] + qualifiers.prefix($0)).joined(separator: " ") }
        }

        init(_ value: String) {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { key(String($0)) }
            name = parts.first ?? ""
            qualifiers = Array(parts.dropFirst()).filter { !$0.isEmpty }
        }

        func qualifiersMatch(_ place: RailPlace, additional: Set<String> = []) -> Bool {
            qualifiers.allSatisfy { qualifier in
                if additional.contains(qualifier) { return true }
                if let country = countryCode(for: qualifier) {
                    return place.countryCode.uppercased() == country
                }
                return containsPhrase(key(place.displayName), qualifier)
                    || containsPhrase(key(place.context), qualifier)
            }
        }

        private func countryCode(for value: String) -> String? {
            switch value {
            case "usa", "u s a", "u s", "united states of america": return "US"
            case "uk", "u k", "great britain": return "GB"
            default:
                return Locale.Region.isoRegions.first {
                    key($0.identifier) == value
                        || english.localizedString(forRegionCode: $0.identifier).map(key) == value
                }?.identifier
            }
        }
    }
}
