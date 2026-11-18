import Foundation

/// Extracts candidate numbers after explicit train labels or known operator/product prefixes.
/// Product names can be ambiguous, so callers must establish journey context separately.
enum TicketTrainNumberParser {
    static let operators = #"(?:amtrak|eurostar|via\s+rail|renfe|sncf|trenitalia|deutsche\s+bahn|db\s+bahn|thalys|nj\s*transit|metra|caltrain|go\s+transit)"#
    static let products = #"(?:northeast\s+regional|acela(?:\s+express)?|tgv(?:\s+inoui)?|ice|ic|ir|ec|ave|frecciarossa|frecciargento|frecciabianca|railjet|rjx|rj|shinkansen|nozomi|hikari|kodama)"#
    private static let numberLabel = #"(?:(?:no\.?|number|numero|n\.|n[º°]|#)\s*)?"#
    private static let token = #"((?:[a-z]{0,3}[0-9]{1,6}[a-z]{0,2}|[0-9][a-z][0-9]{2}))(?![\p{L}\p{N}]|[-/:][0-9])"#
    private static let numericToken = #"([0-9]{1,6})(?![\p{L}\p{N}]|[-/:][0-9])"#
    private static let matchingProducts = #"(?:rjx|rj|ice|ic|ir|ec|tgv(?:\s+inoui)?|ave|railjet|intercity|eurocity)"#
    private static let metadataLine = #"^\s*(?:your\s+)?(?:booking|confirmation|reservation|reference|pnr|order|ticket\s*(?:number|no\.?)|seat|coach|platform|track|address)\b"#

    private static let labelledTrain = #"(?:train|treno)(?![\p{L}\p{N}])\s*"# + numberLabel + token
    private static let numberedService = #"(?:"# + operators + #"(?:\s+(?:"# + products + #"|train))?|"# + products + #")(?:\s+|(?=[0-9]))"# + numberLabel + numericToken
    private static let leadingNumber = #"^\s*(?:"# + labelledTrain + "|" + numberedService + ")"

    /// A purpose such as a meeting or dinner can also follow a genuine passenger journey.
    static func startsWithPassengerJourney(_ heading: String) -> Bool {
        if TicketTextPattern.contains(#"^\s*(?:train|rail)\s+(?:from|to)\b"#, in: heading) { return true }
        return TicketTextPattern.contains(leadingNumber, in: withoutFleetModelNumber(heading))
    }

    /// Calendar locations are usually addresses. Only use a printed leading service here,
    /// and leave an ambiguous street abbreviation like “Ave 416” to the address field.
    static func locationIdentifiesService(_ location: String) -> Bool {
        !TicketTextPattern.contains(#"^\s*ave\b"#, in: location)
            && TicketTextPattern.contains(leadingNumber, in: withoutFleetModelNumber(location))
    }

    static func extract(from text: String) -> String? {
        let explicit = #"(?<![\p{L}\p{N}])"# + labelledTrain
        // Implicit service names only supply numeric train numbers. In particular, EC2N
        // is a London postcode, not EuroCity 2N. Alphanumeric numbers and UK headcodes
        // remain supported after an explicit Train label above.
        let service = #"(?<![\p{L}\p{N}])"# + numberedService
        let lines = withoutFleetModelNumber(text).components(separatedBy: .newlines)
        // Keep a non-whitespace barrier so removing metadata cannot join a bare Train label
        // to an unrelated number farther down the document.
        let eligible = lines.map { isMetadata($0) ? "[metadata]" : $0 }.joined(separator: "\n")
        if let number = TicketTextPattern.firstCapture(explicit, in: eligible), number.count <= 8 {
            return number.uppercased()
        }
        // A service name or abbreviation must not borrow an address/reference number from
        // the next line. Explicit "Train" labels above keep their existing ticket handling.
        for line in lines where !isMetadata(line) {
            if let number = TicketTextPattern.firstCapture(service, in: line), number.count <= 8 {
                return number.uppercased()
            }
        }
        return nil
    }

    /// Keep the old numeric extraction API while retaining independently printed product
    /// evidence for matching. A product must be attached to this exact extracted number.
    static func matchingEvidence(for number: String?, in text: String) -> (identifier: String?, isAmbiguous: Bool) {
        guard let number else { return (nil, false) }
        let numeric = TicketTextPattern.firstCapture(#"^(?:RJX|RJ|ICE|IC|IR|EC|TGV|AVE)([0-9]{1,6})$"#, in: number) ?? number
        guard !numeric.isEmpty, numeric.allSatisfy(\.isNumber) else { return (nil, false) }
        let pattern = #"(?<![\p{L}\p{N}])("# + matchingProducts + #")(?:\s+|(?=[0-9]))"#
            + numberLabel + NSRegularExpression.escapedPattern(for: numeric) + #"(?![\p{L}\p{N}]|[-/:][0-9])"#
        let families = Set(text.components(separatedBy: .newlines).filter { !isMetadata($0) }.flatMap { line in
            TicketTextPattern.ranges(pattern, in: line).compactMap {
                TicketTextPattern.firstCapture(pattern, in: String(line[$0])).map(canonicalProduct)
            }
        })
        guard families.count == 1, let family = families.first else { return (nil, families.count > 1) }
        return (family + " " + numeric, false)
    }

    /// Provider products may carry a route designation (IC8) rather than the service number.
    static func productFamilies(in text: String) -> Set<String> {
        let pattern = #"(?<![\p{L}\p{N}])("# + matchingProducts + #")(?![\p{L}])"#
        return Set(TicketTextPattern.ranges(pattern, in: text).compactMap {
            TicketTextPattern.firstCapture(pattern, in: String(text[$0])).map(canonicalProduct)
        })
    }

    private static func canonicalProduct(_ value: String) -> String {
        let value = value.uppercased()
        if value.hasPrefix("TGV") { return "TGV" }
        if value == "RAILJET" { return "RJ" }
        if value == "INTERCITY" { return "IC" }
        if value == "EUROCITY" { return "EC" }
        return value
    }

    private static func isMetadata(_ line: String) -> Bool { TicketTextPattern.contains(metadataLine, in: line) }

    /// “Frecciarossa 1000” names the fleet. Keep its product name available for a separately
    /// printed service, including “Frecciarossa 1000 9640” and “Frecciarossa 1000 Treno 9640”.
    private static func withoutFleetModelNumber(_ text: String) -> String {
        guard text.contains("1000"), text.localizedCaseInsensitiveContains("frecciarossa"),
              let model = TicketTextPattern.expression(#"\b(frecciarossa)[\t ]*1000(?![\p{L}\p{N}])"#) else { return text }
        return model.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    /// Used only at the start of an endpoint, so operator/product names and their numbers do
    /// not become part of a city. The remaining text still has to pass place validation.
    static func removingServicePrefix(from text: String) -> String {
        let text = withoutFleetModelNumber(TicketLocalizedRailText.removingEastAsianService(from: text))
        let service = #"^(?:"# + operators + #"(?:\s+"# + products + #")?|"# + products + #"|train|rail)(?![\p{L}])"#
        let number = #"(?:\s*(?:(?:train|treno)\s+)?"# + numberLabel + token + #")?"#
        return TicketTextPattern.removingPrefix(service + number + #"[\s:—–-]*"#, from: text)
    }
}
