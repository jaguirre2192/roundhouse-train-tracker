import Foundation

/// Printed railway headings with language-specific service and direction syntax. These
/// qualify only alongside a parsed station pair. An operator mention in event notes is
/// insufficient to classify another activity as a passenger journey.
enum TicketLocalizedRailText {
    private static let eastAsianService = #"^\s*(?:新幹線\s*(?:のぞみ|ひかり|こだま)\s*|[台臺]灣高鐵\s*(?:車次[\s:：]*)?)([0-9]{1,4})(?![0-9])(?:[号號]|(?=[\s:：]|$))"#
    private static let danishService = #"^\s*(?:lyntog|tognummer)\s*(?:nr\.?\s*)?([0-9]{1,5})(?![\p{L}\p{N}]|[-/:][0-9])"#
    private static let ticketHeading = [
        #"^\s*dsb\s+(?:billet(?:ter)?|ticket)\b"#,
        #"^\s*(?:sbb(?:\s+cff(?:\s+ffs)?)?|cff|ffs)\s+(?:ticket|billet|billett|fahrkarte|biglietto)\b"#,
        #"^\s*frecciarossa\s*1000\s*(?:$|[:：]|[0-9]|treno\b)"#
    ].joined(separator: "|")

    static func isItineraryHeading(_ heading: String) -> Bool {
        TicketTextPattern.contains(ticketHeading, in: heading)
            || TicketTextPattern.contains(eastAsianService, in: heading)
            || isSwissStationRoute(heading)
            || inlineRoute(in: heading) != nil
    }

    private static func isSwissStationRoute(_ heading: String) -> Bool {
        guard let route = TicketTextPattern.firstCapture(#"^\s*(?:sbb(?:\s+cff(?:\s+ffs)?)?|cff|ffs)\s*:\s*(.+(?:→|->).+)$"#, in: heading)
        else { return false }
        // Operator bulletins use arrows too. Require at least one printed station marker.
        return TicketTextPattern.contains(#"\b(?:hb|hbf|sbb|cff|ffs|cornavin|bahnhof|flughafen|aéroport|stazione)\s*(?:→|->|$)"#, in: route)
    }

    static func serviceNumber(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            if let number = TicketTextPattern.firstCapture(eastAsianService, in: line)
                ?? TicketTextPattern.firstCapture(danishService, in: line) { return number }
        }
        return nil
    }

    static func removingEastAsianService(from text: String) -> String {
        TicketTextPattern.removingPrefix(eastAsianService, from: text)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":：")))
    }

    /// Bare “de”, “a” and “nach” also occur in names and prose. Require a passenger-train
    /// heading and its paired direction words, then pass the two stations to normal validation.
    static func inlineRoute(in line: String) -> (origin: String, destination: String)? {
        let format: (heading: String, divider: String)
        if line.localizedCaseInsensitiveContains(" von ") {
            format = (#"^\s*(?:(?:fahrt\s+mit\s+)?(?:ice|ic|ec|ir|rjx?)\s*[0-9]{1,6}|zug(?:fahrt)?)\s+von\s+(.+)$"#, #"\s+nach\s+"#)
        } else if line.localizedCaseInsensitiveContains(" de ") {
            if line.localizedCaseInsensitiveContains(" à ") {
                format = (#"^\s*(?:train|(?:sncf\s+)?tgv(?:\s+inoui)?\s*[0-9]{1,6})\s+de\s+(.+)$"#, #"\s+à\s+"#)
            } else {
                format = (#"^\s*(?:tren|(?:renfe\s+)?ave\s*[0-9]{1,6})\s+de\s+(.+)$"#, #"\s+a\s+"#)
            }
        } else { return nil }
        guard let tail = TicketTextPattern.firstCapture(format.heading, in: line) else { return nil }
        let dividers = TicketTextPattern.ranges(format.divider, in: tail)
        guard dividers.count == 1, let divider = dividers.first else { return nil }
        return (String(tail[..<divider.lowerBound]), String(tail[divider.upperBound...]))
    }
}
