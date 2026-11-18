import Foundation
import TrainTrackerCore

enum RailStationMatchMerger {
    static func merge(
        _ matches: [RailStationMatch],
        query: String,
        limit: Int = 30
    ) -> [RailStationMatch] {
        let candidates: [RailStationMatch]
        if matches.contains(where: { matchesAllQueryTokens($0.station, query: query) }) {
            candidates = matches.filter { matchesAllQueryTokens($0.station, query: query) }
        } else {
            candidates = matches
        }

        let sorted = candidates.enumerated().sorted { lhs, rhs in
            let lhsRank = stationRank(lhs.element.station, query: query)
            let rhsRank = stationRank(rhs.element.station, query: query)
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            let nameComparison = lhs.element.station.displayName.localizedStandardCompare(
                rhs.element.station.displayName
            )
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }

            if lhs.element.station.countryCode != rhs.element.station.countryCode {
                return lhs.element.station.countryCode < rhs.element.station.countryCode
            }

            let lhsPreferred = preferredSource(for: lhs.element.station) == lhs.element.source
            let rhsPreferred = preferredSource(for: rhs.element.station) == rhs.element.source
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.offset < rhs.offset
        }

        var values: [RailStationMatch] = []
        for candidate in sorted.map(\.element) {
            guard !values.contains(where: { isDuplicate(candidate.station, of: $0.station) }) else {
                continue
            }
            values.append(candidate)
            if values.count == limit { break }
        }
        return values
    }

    private static func stationRank(_ station: Station, query: String) -> Int {
        let query = normalized(query)
        let name = normalized(station.displayName)
        let codes = station.codes.values.map(normalized)
        if codes.contains(query) || name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if matchesAllQueryTokens(station, query: query) { return 2 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 3 }
        return 4
    }

    private static func isDuplicate(_ station: Station, of other: Station) -> Bool {
        guard station.countryCode.caseInsensitiveCompare(other.countryCode) == .orderedSame else {
            return false
        }

        let sharedCode = sharesStationCode(station, other)
        if sharedCode { return true }

        guard canonicalStationName(station.displayName) == canonicalStationName(other.displayName),
              station.location.latitude != 0 || station.location.longitude != 0,
              other.location.latitude != 0 || other.location.longitude != 0
        else { return false }

        return abs(station.location.latitude - other.location.latitude) < 0.02
            && abs(station.location.longitude - other.location.longitude) < 0.02
    }

    private static func preferredSource(for station: Station) -> RailSource {
        station.countryCode.caseInsensitiveCompare("US") == .orderedSame ? .unitedStates : .europe
    }

    private static func canonicalStationName(_ value: String) -> String {
        var words = normalized(value).split(separator: " ").map(String.init)
        if words.last == "station" { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func matchesAllQueryTokens(_ station: Station, query: String) -> Bool {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return false }
        let candidateTokens = tokens(station.displayName)
            + station.codes.values.flatMap { tokens($0) }
        return queryTokens.allSatisfy { queryToken in
            candidateTokens.contains { $0.hasPrefix(queryToken) }
        }
    }

    private static func sharesStationCode(_ station: Station, _ other: Station) -> Bool {
        let stationCodes = Set(station.codes.values.map(normalized))
        let otherCodes = Set(other.codes.values.map(normalized))
        if !stationCodes.isDisjoint(with: otherCodes) { return true }

        let stationTokens = Set(station.codes.values.flatMap { tokens($0) })
        let otherTokens = Set(other.codes.values.flatMap { tokens($0) })
        return stationCodes.contains { $0.count >= 3 && otherTokens.contains($0) }
            || otherCodes.contains { $0.count >= 3 && stationTokens.contains($0) }
    }

    private static func tokens(_ value: String) -> [String] {
        normalized(value).split(separator: " ").map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
