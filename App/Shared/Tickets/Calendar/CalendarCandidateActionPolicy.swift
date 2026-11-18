import Foundation

enum CalendarCandidateActionPolicy {
    static func canFindDirectly(_ candidate: CalendarJourneyCandidate) -> Bool {
        guard candidate.classification.confidence == .high,
              !candidate.classification.hasConflictingTrainProducts,
              !candidate.snapshot.isAllDay, !candidate.snapshot.isCancelled,
              let origin = candidate.classification.originGuess,
              let destination = candidate.classification.destinationGuess,
              let number = candidate.classification.trainNumberGuess,
              !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return TicketRouteReviewPolicy.canConfirm(
            origin: origin, destination: destination,
            requiresDepartureTime: false, departureTimeConfirmed: true
        )
    }
}
