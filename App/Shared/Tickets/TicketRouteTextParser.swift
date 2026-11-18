import Foundation

/// Parses one explicit route at a time. Line boundaries are meaningful: prose and contact
/// details elsewhere in booking notes must not become part of a station name.
enum TicketRouteTextParser {
    private static let separators = [#"\s*(?:→|->)\s*"#, #"\s+to\s+"#, #"\s+[—–-]\s+"#]
    private static let metadata = #"(?:train\s*(?:no\.?|number|#)?\s*[a-z]*[0-9]|seat\b|coach\b|platform\b|track\b|booking\b|confirmation\b|reservation\b|pnr\b|departure\b|arrival\b|address\b)"#
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;|—–-!?"))
    private static let departureLabel = #"^(?:departure(?:\s+station)?|origin|from|fra|von|abfahrtsbahnhof|(?:estaci[oó]n\s+de\s+)?origen|(?:gare\s+de\s+)?d[ée]part)\s*:\s*(.+)$"#
    private static let arrivalLabel = #"^(?:arrival(?:\s+station)?|destination|to|til|nach|zielbahnhof|(?:estaci[oó]n\s+de\s+)?destino|(?:gare\s+d['’])?arriv[ée]e)\s*:\s*(.+)$"#
    // Event schedules also use arrows. Reject bounded event phrases, not bare words such
    // as Summit or Exhibition that can legitimately name a station.
    private static let eventPhrase = #"\b(?:summit|conference|congress|symposium|seminar|convention)\s+(?:19|20)[0-9]{2}\b|\b(?:speakers?|delegates?|sponsors?|welcome|farewell|networking|gala|evening|board|team|working|annual|vip)(?:['’]s|['’])?\s+(?:dinner|lunch|breakfast|reception|banquet)\b|^(?:dinner|lunch|breakfast|reception|banquet)$"#

    static func extract(from text: String) -> (origin: String, destination: String)? {
        let lines = routeLines(text)
        guard !requiresMultipleJourneyReview(from: text) else { return nil }
        if let route = labelledRoute(in: lines) { return route }
        for line in lines {
            if let route = TicketLocalizedRailText.inlineRoute(in: line) {
                let origin = cleanOrigin(route.origin)
                let destination = cleanDestination(route.destination)
                if validPair(origin, destination) { return (origin, destination) }
            }
            for separator in separators {
                for range in TicketTextPattern.ranges(separator, in: line) {
                    let origin = cleanOrigin(String(line[..<range.lowerBound]))
                    let destination = cleanDestination(String(line[range.upperBound...]))
                    if validPair(origin, destination) { return (origin, destination) }
                }
            }
        }
        return nil
    }

    /// A connected return itinerary cannot be reduced to its first train: that train may only
    /// reach the outbound interchange. Ask the person which complete journey to track.
    static func requiresMultipleJourneyReview(from text: String) -> Bool {
        let endpoints = labelledEndpoints(in: routeLines(text))
        guard endpoints.origins.count > 2, endpoints.origins.count == endpoints.destinations.count,
              let first = endpoints.origins.first, let last = endpoints.destinations.last else { return false }
        return stationKey(first) == stationKey(last)
    }

    private static func routeLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 1_000 }
    }

    private static func labelledEndpoints(in lines: [String]) -> (origins: [String], destinations: [String]) {
        var origins: [String] = []
        var destinations: [String] = []
        for line in lines {
            if let value = TicketTextPattern.firstCapture(departureLabel, in: line) {
                let station = cleanDestination(value)
                if plausiblePlace(station) { origins.append(station) }
            }
            if let value = TicketTextPattern.firstCapture(arrivalLabel, in: line) {
                let station = cleanDestination(value)
                if plausiblePlace(station) { destinations.append(station) }
            }
        }
        return (origins, destinations)
    }

    private static func labelledRoute(in lines: [String]) -> (origin: String, destination: String)? {
        let (origins, destinations) = labelledEndpoints(in: lines)
        if origins.count == 1, destinations.count == 1,
           let origin = origins.first, let destination = destinations.first,
           validPair(origin, destination) {
            return (origin, destination)
        }
        return chainedLegs(origins: origins, destinations: destinations)
    }

    /// Multi-leg bookings list each leg's From/To. When the legs connect (each arrival is the
    /// next departure), the journey runs from the first departure to the last arrival; a chain
    /// that returns to its start is a round trip, so the outbound leg is used. Legs that don't
    /// connect stay unparsed for review rather than guessing crossed endpoints.
    private static func chainedLegs(origins: [String], destinations: [String]) -> (origin: String, destination: String)? {
        guard origins.count >= 2, origins.count == destinations.count else { return nil }
        for index in 0..<(origins.count - 1)
        where stationKey(destinations[index]) != stationKey(origins[index + 1]) {
            return nil
        }
        guard let first = origins.first, let last = destinations.last else { return nil }
        if stationKey(first) == stationKey(last) {
            let outbound = destinations[0]
            return validPair(first, outbound) ? (first, outbound) : nil
        }
        return validPair(first, last) ? (first, last) : nil
    }

    private static func stationKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "station" }
            .joined()
    }

    private static func cleanOrigin(_ text: String) -> String {
        var value = text
        // Commas belong to city/region names. Only explicit heading delimiters split labels.
        if let boundary = TicketTextPattern.ranges(#"[:;|]|\s+[—–-]\s+"#, in: value).last {
            value = String(value[boundary.upperBound...])
        }
        value = value.trimmingCharacters(in: trimCharacters)
        value = TicketTextPattern.removingPrefix(#"^(?:your\s+)?(?:journey|trip|travel)\s+"#, from: value)
        value = TicketTrainNumberParser.removingServicePrefix(from: value)
        value = TicketTextPattern.removingPrefix(#"^(?:(?:ticket|booking|journey|trip)\s+)?from\s+"#, from: value)
        return normalizedStation(value.trimmingCharacters(in: trimCharacters))
    }

    private static func cleanDestination(_ text: String) -> String {
        var value = text.trimmingCharacters(in: trimCharacters)
        if let purpose = TicketTextPattern.ranges(#"\s+for\s+(?:(?:a|an|the|my|our|client|team|business|work)\s+)*(?:meeting|conference|dinner)\b"#, in: value).first {
            value = String(value[..<purpose.lowerBound])
        }
        // Cut labelled ticket metadata, including comma-separated Train/Seat fields, while
        // preserving punctuation in Washington, DC and St. Louis.
        let boundary = #"(?:[,;|]\s*|\s+[—–-]\s+|\s+)(?="# + metadata + #")"#
        if let range = TicketTextPattern.ranges(boundary, in: value).first {
            value = String(value[..<range.lowerBound])
        }
        // A clock can follow an explicitly labelled station, but cannot be a station itself.
        if let range = TicketTextPattern.ranges(#"\s+(?:at\s+)?[0-2]?[0-9]:[0-5][0-9](?:\s*[ap]m)?\s*$"#, in: value).first {
            value = String(value[..<range.lowerBound])
        }
        return normalizedStation(value.trimmingCharacters(in: trimCharacters.union(CharacterSet(charactersIn: ".,"))))
    }

    /// Calendar providers use city-first station labels that include words otherwise treated
    /// as prose. Normalize only complete, known station aliases before conservative validation.
    /// Canonical names also match the station search aliases used after review.
    private static func normalizedStation(_ value: String) -> String {
        if TicketTextPattern.contains(#"^Washington,\s*Union Station$"#, in: value) {
            return "Washington Union Station"
        }
        if TicketTextPattern.contains(
            #"^(?:New York,?\s+)?Moynihan Train Hall(?: at Penn (?:Sta\.?|Station))?$"#,
            in: value
        ) {
            return "New York Penn Station"
        }
        return value
    }

    private static func validPair(_ origin: String, _ destination: String) -> Bool {
        plausiblePlace(origin) && plausiblePlace(destination)
            && origin.localizedCaseInsensitiveCompare(destination) != .orderedSame
    }

    private static func plausiblePlace(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64,
              value.split(whereSeparator: { $0.isWhitespace }).count <= 8,
              value.filter({ $0 == "," }).count <= 1,
              TicketTextPattern.contains(#"^[\p{L}\p{M}][\p{L}\p{M}0-9\s.'’(),&-]*$"#, in: value) else { return false }
        let prose = #"\b(?:train|rail|from|to|please|thanks?|booking|confirmation|reservation|ticket|meeting|project|call|agenda|workshop|training|reminder|platform|coach|seat|departure|arrival|address|hotel|office|email|https?|www|see|attached|details|boarding|arrive|departs|contact|your|regards)\b"#
        // TGV is also a station suffix (Avignon TGV, Aix-en-Provence TGV). Validate
        // the place before that suffix, while keeping the full name for station lookup.
        // Bare TGV and service labels such as TGV INOUI 9579 remain invalid endpoints.
        let placeWords = TicketTextPattern.firstCapture(#"^(.+?)[\s-]+TGV$"#, in: value) ?? value
        guard !TicketTextPattern.contains(prose, in: value),
              !TicketTextPattern.contains(eventPhrase, in: value),
              !TicketTextPattern.contains(#",.*[0-9]"#, in: value),
              !TicketTextPattern.contains(#"\b"# + TicketTrainNumberParser.operators + #"\b"#, in: placeWords),
              !TicketTextPattern.contains(#"\b"# + TicketTrainNumberParser.products + #"\b"#, in: placeWords) else { return false }
        return true
    }
}
