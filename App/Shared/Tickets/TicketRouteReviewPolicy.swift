import Foundation

enum TicketRouteReviewPolicy {
    static func canConfirm(
        origin: String, destination: String,
        requiresDepartureTime: Bool, departureTimeConfirmed: Bool
    ) -> Bool {
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return !origin.isEmpty && !destination.isEmpty
            && origin.localizedCaseInsensitiveCompare(destination) != .orderedSame
            && (!requiresDepartureTime || departureTimeConfirmed)
    }
}
