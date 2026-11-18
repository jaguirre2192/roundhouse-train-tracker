import Foundation

/// How strongly free text (a calendar event, a shared email, a shared note) appears to describe
/// an actual train journey. Kept conservative: callers should prefer `nil` over a bad guess.
enum TicketRouteConfidence: String, Sendable, Hashable, Codable {
    case high
    case medium
}

struct TicketRouteMatch: Sendable, Hashable {
    let confidence: TicketRouteConfidence
    let evidence: [String]
    let originGuess: String?
    let destinationGuess: String?
    let trainNumberGuess: String?
    var trainMatchingIdentifier: String? = nil
    var hasConflictingTrainProducts = false
}

/// Conservative, dependency-free text heuristics for spotting train journeys inside free text
/// (event titles/notes/locations, forwarded emails, shared plain text). Shared by calendar
/// classification and share-extension parsing so both surfaces agree on what counts as evidence.
enum TicketRouteTextHeuristics {
    private static let strongKeywords: [String: String] = [
        "amtrak": "Mentions Amtrak",
        "eurostar": "Mentions Eurostar",
        "via rail": "Mentions VIA Rail",
        "renfe": "Mentions Renfe",
        "sncf": "Mentions SNCF",
        "tgv": "Mentions TGV",
        "trenitalia": "Mentions Trenitalia",
        "deutsche bahn": "Mentions Deutsche Bahn",
        "db bahn": "Mentions Deutsche Bahn",
        "thalys": "Mentions Thalys",
        "acela": "Mentions Acela",
        "nj transit": "Mentions NJ Transit",
        "njtransit": "Mentions NJ Transit",
        "metra": "Mentions Metra",
        "caltrain": "Mentions Caltrain",
        "go transit": "Mentions GO Transit",
        "shinkansen": "Mentions Shinkansen",
        "eurail": "Mentions a Eurail pass",
        "interrail": "Mentions an Interrail pass",
        "train ticket": "Mentions a train ticket",
        "rail ticket": "Mentions a rail ticket",
        "train #": "Mentions a train number",
        "trainline": "Mentions Trainline",
    ]

    /// Weaker signals supplement a candidate; they never establish journey eligibility.
    private static let supportingKeywords: [String: String] = [
        "platform": "Mentions a platform",
        "coach": "Mentions a coach assignment",
        "seat": "Mentions a seat assignment",
        "pnr": "Mentions a booking reference",
        "booking reference": "Mentions a booking reference",
        "e-ticket": "Mentions an e-ticket",
        "boarding": "Mentions boarding details",
    ]
    private static let sortedStrongKeywords = strongKeywords.sorted { $0.key < $1.key }
    private static let sortedSupportingKeywords = supportingKeywords.sorted { $0.key < $1.key }

    /// Requires an explicit rail reference or a service number supported by a route. Number
    /// extraction alone is not journey evidence: short product names also occur in addresses
    /// and unrelated codes (for example, "Ave 416" or "EC 2026").
    static func match(title: String, supportingText: [String?]) -> TicketRouteMatch? {
        let fields = ([title] + supportingText.compactMap { $0 })
            .map { String($0.prefix(8_000)) }
            .filter { !$0.isEmpty }
        guard !fields.isEmpty else { return nil }
        let lowercasedFields = fields.map { $0.lowercased() }
        // An operator's meeting, workshop, or project notice is not a passenger journey.
        // Only inspect the heading; booking notes can legitimately mention meetings en route.
        let heading = title.components(separatedBy: .newlines).first ?? title
        let nonJourney = #"\b(?:meeting|workshop|webinar|training|project|presentation|renovation|conference\s+call)\b"#
        guard !TicketTextPattern.contains(nonJourney, in: heading) else { return nil }

        var evidence: [String] = []
        var hasExplicitRailSignal = false
        // The bare word "train" or "rail" is journey evidence in the title. In notes or a
        // location ("dinner by the train station") it only supports a route or train number.
        var mentionsTrainOutsideTitle = false
        for (index, field) in lowercasedFields.enumerated() {
            for (keyword, reason) in sortedStrongKeywords where TicketTextPattern.containsWord(keyword, in: field) {
                if !evidence.contains(reason) { evidence.append(reason) }
                hasExplicitRailSignal = true
            }
            if ["train", "rail"].contains(where: { TicketTextPattern.containsWord($0, in: field) }) {
                let reason = "Mentions a train"
                if !evidence.contains(reason) { evidence.append(reason) }
                if index == 0 {
                    hasExplicitRailSignal = true
                } else {
                    mentionsTrainOutsideTitle = true
                }
            }
        }
        let trainNumber = fields.lazy.compactMap { extractTrainNumber(from: $0) }.first
        let trainEvidence = TicketTrainNumberParser.matchingEvidence(for: trainNumber, in: fields.joined(separator: "\n"))
        if trainNumber != nil {
            evidence.append("Recognized a train number")
        }
        guard hasExplicitRailSignal || trainNumber != nil || mentionsTrainOutsideTitle else { return nil }

        for field in lowercasedFields {
            for (keyword, reason) in sortedSupportingKeywords where TicketTextPattern.containsWord(keyword, in: field) {
                if !evidence.contains(reason) { evidence.append(reason) }
            }
        }

        var origin: String?
        var destination: String?
        for field in fields {
            if let route = extractRoute(from: field) {
                origin = route.origin
                destination = route.destination
                evidence.append("Recognized a route pattern")
                break
            }
        }

        let hasRoute = origin != nil && destination != nil
        if mentionsTrainOutsideTitle, hasRoute || trainNumber != nil { hasExplicitRailSignal = true }
        guard hasExplicitRailSignal || (trainNumber != nil && hasRoute) else { return nil }
        let confidence: TicketRouteConfidence = hasRoute ? .high : .medium
        return TicketRouteMatch(
            confidence: confidence,
            evidence: evidence,
            originGuess: origin,
            destinationGuess: destination,
            trainNumberGuess: trainNumber,
            trainMatchingIdentifier: trainEvidence.identifier,
            hasConflictingTrainProducts: trainEvidence.isAmbiguous
        )
    }

    static func extractRoute(from text: String) -> (origin: String, destination: String)? {
        TicketRouteTextParser.extract(from: text)
    }

    static func extractTrainNumber(from text: String) -> String? {
        TicketTrainNumberParser.extract(from: text)
    }
}
