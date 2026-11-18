import Foundation
import TrainTrackerCore

/// A supplier can clear its position array while a delayed train is still on the road.
/// Keep the operating run and the observation clock, never the device's check time.
struct TripForegroundRecovery: Equatable, Codable {
    static let maximumAge: TimeInterval = 8 * 60 * 60
    static let retryInterval: TimeInterval = 15 * 60

    private let tripID: RailIdentifier
    private let provider: String
    private let serviceDate: Date
    private var underwayAt: Date?
    private var closedAt: Date?
    var lastSlowAttempt: Date?

    func checkIsDue(at date: Date, lastSuccess: Date?) -> Bool {
        let last = [lastSlowAttempt, lastSuccess].compactMap { $0 }.max()
        return last.map { date.timeIntervalSince($0) >= Self.retryInterval } ?? true
    }

    private init(trip: TrainTrip) {
        tripID = trip.id
        provider = trip.source
        serviceDate = trip.serviceDate
    }

    private func matches(_ trip: TrainTrip) -> Bool {
        tripID == trip.id && provider == trip.source && serviceDate == trip.serviceDate
    }

    static func observing(_ prior: Self?, trip: TrainTrip, at date: Date) -> Self? {
        var state = prior.flatMap { $0.matches(trip) ? $0 : nil }
        guard date.timeIntervalSinceReferenceDate.isFinite, trip.stopTimes.count >= 2 else { return state }
        if closed(trip, at: date) {
            if state?.underwayAt != nil {
                state?.underwayAt = nil
                state?.closedAt = date
                state?.lastSlowAttempt = nil
            }
            return state
        }
        guard let observed = underwayObservation(in: trip, at: date),
              observed > (state?.underwayAt ?? .distantPast), observed > (state?.closedAt ?? .distantPast) else { return state }
        var update = state ?? Self(trip: trip)
        update.underwayAt = observed
        update.closedAt = nil
        return update
    }

    /// Extend the existing two-hour allowance only for this train's own progress. The
    /// second interval is a sparse foreground check; fresh HTTP success cannot renew it.
    func cadence(for trip: TrainTrip, at date: Date) -> TripForegroundCadence? {
        guard matches(trip), let underwayAt, !Self.closed(trip, at: date) else { return nil }
        let age = date.timeIntervalSince(underwayAt)
        guard age.isFinite, age >= 0, age <= Self.maximumAge else { return nil }
        return age <= TripAutomaticRefreshPolicy.recoveryWindow ? .regular : .occasional
    }

    private static func closed(_ trip: TrainTrip, at date: Date) -> Bool {
        trip.isCancelled || trip.stopTimes.last?.isCancelled == true
            || RailJourneyEvidence(trip: trip, referenceDate: date).isArrivalConfirmed
    }

    private static func underwayObservation(in trip: TrainTrip, at date: Date) -> Date? {
        guard let origin = trip.stopTimes.first,
              let departure = origin.scheduledDeparture ?? origin.expectedDeparture ?? origin.scheduledArrival else { return nil }
        let earliest = max(departure, date.addingTimeInterval(-maximumAge))
        // A dated departure or intermediate arrival establishes movement. A platform,
        // prediction, undated passage flag, or a vehicle waiting at the origin does not.
        let departureReports = trip.stopTimes.dropLast().filter { !$0.isCancelled }.flatMap { call -> [Date] in
            [call.isPassed ? call.passageObservedAt : nil, call.id == origin.id ? nil : call.arrivalObservedAt]
                .compactMap { $0 }.filter { $0 >= earliest && $0 <= date }
        }
        var last = departureReports.max()
        if let fix = RailJourneyEvidence.latestRealPosition(in: trip, at: date, maximumAge: maximumAge),
           fix.asOf >= earliest, fix.asOf <= date, fix.asOf > (last ?? .distantPast) {
            let atFix = RailJourneyEvidence(trip: trip, referenceDate: fix.asOf)
            if atFix.basis == .vehiclePosition, !atFix.isArrivalConfirmed, atFix.confirmedPassedStopIDs.contains(origin.id) {
                last = fix.asOf
            }
        }
        return last
    }
}

enum TripForegroundCadence {
    case regular, occasional

    static func forTrip(_ trip: TrainTrip, journal: TripChangeJournal, at date: Date) -> Self? {
        if TripAutomaticRefreshPolicy.isWithinRecoveryWindow(trip, at: date) { return .regular }
        return journal.recoveryForPolling(trip, at: date)?.cadence(for: trip, at: date)
    }
}
