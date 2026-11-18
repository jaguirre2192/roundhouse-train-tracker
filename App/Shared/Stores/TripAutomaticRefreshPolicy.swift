import Foundation
import TrainTrackerCore

enum TripAutomaticRefreshPolicy {
    static let recoveryWindow: TimeInterval = 2 * 60 * 60
    static let unknownTimetableWindow: TimeInterval = 48 * 60 * 60

    /// Passed-stop flags can be inferred from the timetable. Keep checking long
    /// enough to recover revised estimates without polling historical trips forever.
    static func isWithinRecoveryWindow(_ trip: TrainTrip, at date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        // A delayed train can outlive every saved estimate. Its matched real position
        // earns a bounded chance to recover; repeatedly fetching old GPS cannot renew it.
        // This is polling grace, not a claim that a two-hour-old position is live.
        let arrivalConfirmed = RailJourneyEvidence(trip: trip, referenceDate: date).isArrivalConfirmed
        if !arrivalConfirmed,
           RailJourneyEvidence.latestRealPosition(in: trip, at: date, maximumAge: recoveryWindow) != nil {
            return true
        }
        let hasRecentReportedStop = trip.stopTimes.contains { stop in
            guard !stop.isCancelled, stop.hasConfirmedArrival(at: date) else { return false }
            return [stop.arrivalObservedAt, stop.isPassed ? stop.passageObservedAt : nil]
                .compactMap { $0 }.contains { observedAt in
                    let age = date.timeIntervalSince(observedAt)
                    return age.isFinite && age >= -120 && age <= recoveryWindow
                }
        }
        if !arrivalConfirmed && hasRecentReportedStop { return true }
        let latestStopTime = trip.stopTimes.flatMap { stop in
            [stop.scheduledArrival, stop.scheduledDeparture, stop.expectedArrival, stop.expectedDeparture]
                .compactMap { $0 }
        }.filter { $0.timeIntervalSinceReferenceDate.isFinite }.max()

        if let latestStopTime {
            return date <= latestStopTime.addingTimeInterval(recoveryWindow)
        }

        // Service dates are encoded as a UTC calendar day. This fallback allows
        // missing or empty stop data to recover across time zones and overnight.
        guard trip.serviceDate.timeIntervalSinceReferenceDate.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let serviceDay = calendar.startOfDay(for: trip.serviceDate)
        return date <= serviceDay.addingTimeInterval(unknownTimetableWindow)
    }

    static func shouldRefreshAutomatically(_ trip: TrainTrip, at date: Date) -> Bool {
        isWithinRecoveryWindow(trip, at: date)
    }

    /// Prefer timetable-current trips without trusting provider passage flags. A recently ended
    /// or untimed trip remains visible only as a recovery fallback.
    static func preferredActiveTrip(in trips: [TrainTrip], at date: Date) -> TrainTrip? {
        let candidates = trips.filter { isWithinRecoveryWindow($0, at: date) }
        let timed = candidates.map { (trip: $0, progress: RailJourneyProgress(trip: $0, referenceDate: date)) }
        if let current = timed.first(where: { $0.progress.phase == .underway }) {
            return current.trip
        }
        let next = timed
            .filter { $0.progress.phase == .upcoming || $0.progress.phase == .departureSoon }
            .sorted { ($0.progress.departureDate ?? .distantFuture) < ($1.progress.departureDate ?? .distantFuture) }
            .first
        return next?.trip ?? candidates.first
    }
}
