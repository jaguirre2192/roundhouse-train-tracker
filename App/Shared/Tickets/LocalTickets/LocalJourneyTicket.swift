import Foundation

/// An original ticket kept on this device, with its locally extracted details and any journeys
/// the person explicitly linked it to. Links reference saved plan and train IDs only.
struct LocalJourneyTicket: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// SHA-256 of the original bytes. Importing identical bytes again returns this record.
    let digest: String
    let createdAt: Date
    let kind: ShareManifest.Kind
    let filename: String?
    let mimeType: String
    var suggestion: TicketRouteSuggestion
    var details: TicketTextDetails
    var linkedPlanIDs: Set<UUID> = []
    var linkedTripIDs: Set<String> = []
    /// True until the person tracks, links or explicitly keeps the ticket without a journey.
    var isDraft = true
    var updatedAt: Date

    var isLinked: Bool { !linkedPlanIDs.isEmpty || !linkedTripIDs.isEmpty }

    /// A complex booking remains unfinished until the person explicitly finishes reviewing it.
    /// Clear the journey just chosen so its details cannot be reused for a different leg.
    mutating func finishLink() {
        guard suggestion.routeReviewReason == .multipleJourneys else {
            isDraft = false
            return
        }
        isDraft = true
        suggestion = suggestion.revised(
            origin: .some(nil), destination: .some(nil), trainNumber: .some(nil),
            departureDate: .some(nil), requiresDepartureTime: true, departureWallClock: .some(nil),
            originPlace: .some(nil), destinationPlace: .some(nil),
            originWasReviewed: true, destinationWasReviewed: true
        )
    }

    var title: String {
        if let origin = suggestion.originGuess, let destination = suggestion.destinationGuess {
            return "\(origin) → \(destination)"
        }
        return filename ?? kindTitle
    }

    var kindTitle: String {
        switch kind {
        case .pdf: "PDF ticket"
        case .image: "Ticket image"
        case .emailMessage: "Booking email"
        case .text: "Ticket text"
        case .url: "Ticket link"
        }
    }

    var hasVisualOriginal: Bool { kind == .pdf || kind == .image }

    static func mimeType(for kind: ShareManifest.Kind, payload: Data) -> String {
        switch kind {
        case .pdf: return "application/pdf"
        case .emailMessage: return "message/rfc822"
        case .text, .url: return "text/plain"
        case .image:
            let bytes = [UInt8](payload.prefix(12))
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
            if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return "image/heic" }
            return "image/jpeg"
        }
    }
}
