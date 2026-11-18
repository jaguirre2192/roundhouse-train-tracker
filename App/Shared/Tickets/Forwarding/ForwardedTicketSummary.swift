import Foundation

/// Mirrors the backend's `ForwardedTicketSummary` (`GET /v1/forwarding/tickets`). The backend
/// deliberately reports only `hasArtifact`, not a MIME type — the real type is only known once
/// the artifact itself is downloaded (see `ForwardingClient.artifact`).
struct ForwardedTicketSummary: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let subject: String
    let sender: String
    let receivedAt: String
    let operatorName: String?
    let trainNumber: String?
    let originName: String?
    let destinationName: String?
    let departureTime: String?
    let arrivalTime: String?
    let bookingReference: String?
    let passengerName: String?
    let coach: String?
    let seat: String?
    let hasArtifact: Bool
}

extension ForwardedTicketSummary: TicketSummaryDisplaying {
    var displayTitle: String {
        if let trainNumber, let operatorName { return "\(operatorName) \(trainNumber)" }
        return operatorName ?? subject
    }

    var route: String? {
        guard let originName, let destinationName else { return nil }
        return "\(originName) → \(destinationName)"
    }

    var sourceLabel: String { "Forwarded from \(sender)" }
    var receivedAtSortKey: String { receivedAt }
}

/// Mirrors the backend's `ForwardingAliasStatus` (`GET/POST /v1/forwarding/alias`,
/// `POST /v1/forwarding/alias/rotate`). The backend stores an alias nonce plus a token hash and
/// re-derives the address with its managed secret for authenticated status reads.
struct ForwardingAliasStatus: Codable, Sendable, Equatable {
    let active: Bool
    let address: String?
    let createdAt: String?
    let rotatedAt: String?
}
