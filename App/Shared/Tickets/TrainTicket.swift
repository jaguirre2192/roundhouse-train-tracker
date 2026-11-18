import Foundation

struct GmailConnection: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let emailAddress: String
    let connectedAt: String
    let lastScanAt: String?
    let lastError: String?
}

struct TrainTicketArtifact: Codable, Sendable, Hashable {
    let partId: String
    let attachmentId: String?
    let filename: String
    let mimeType: String
}

struct TrainTicket: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let emailAddress: String
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
    let artifact: TrainTicketArtifact?

    var displayTitle: String {
        if let trainNumber, let operatorName { return "\(operatorName) \(trainNumber)" }
        return operatorName ?? subject
    }

    var route: String? {
        guard let originName, let destinationName else { return nil }
        return "\(originName) → \(destinationName)"
    }

    var receivedDate: Date? {
        ISO8601DateFormatter().date(from: receivedAt)
    }
}

extension TrainTicket: TicketSummaryDisplaying {
    var hasArtifact: Bool { artifact != nil }
    var sourceLabel: String { "Inbox: \(emailAddress)" }
    var receivedAtSortKey: String { receivedAt }
}
