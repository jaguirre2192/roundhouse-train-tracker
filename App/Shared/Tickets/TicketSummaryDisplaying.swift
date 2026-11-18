import Foundation

/// Common shape shared by every ticket source (Gmail import, ticket forwarding, and any future
/// source) so the row and detail UI can be written once and reused instead of duplicated per
/// source.
protocol TicketSummaryDisplaying: Identifiable, Hashable where ID == String {
    var displayTitle: String { get }
    var route: String? { get }
    var subject: String { get }
    var operatorName: String? { get }
    var trainNumber: String? { get }
    var originName: String? { get }
    var destinationName: String? { get }
    var departureTime: String? { get }
    var bookingReference: String? { get }
    var passengerName: String? { get }
    var coach: String? { get }
    var seat: String? { get }
    var hasArtifact: Bool { get }
    /// Shown in the detail view's "Source" section, e.g. "Inbox: rider@example.test" or
    /// "Forwarded from tickets@amtrak.com".
    var sourceLabel: String { get }
    /// Drives the row's "just updated" sheen; any monotonically-comparable-as-a-string value works.
    var receivedAtSortKey: String { get }
}

/// Abstracts "how do I fetch this ticket's original attachment / cached barcode" across ticket
/// sources, so `TrainTicketDetailView` doesn't need to know whether it's showing a Gmail-imported
/// or forwarded ticket. `@MainActor`-isolated because both real implementations are MainActor
/// stores and the only caller is a SwiftUI view — erasing that isolation through the protocol
/// would force every call site to treat a same-actor call as a cross-actor send.
@MainActor
protocol TicketArtifactSource {
    func cachedBarcode(ticketID: String) async -> Data?
    func artifactData(ticketID: String) async throws -> (data: Data, mimeType: String)
    func saveBarcode(_ data: Data, ticketID: String) async
}

enum TicketArtifactError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This ticket's attachment is no longer available."
    }
}
