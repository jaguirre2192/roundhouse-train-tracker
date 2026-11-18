import Foundation

/// Vehicle observations are separate from clock-based journey estimates. A phone's location
/// is deliberately not an input: being near a train does not establish that its owner boarded.
public struct RailJourneyEvidence: Equatable, Sendable {
    public enum Basis: Equatable, Sendable { case unconfirmed, reportedPassage, vehiclePosition }

    public let confirmedPassedStopIDs: Set<String>
    public let isArrivalConfirmed: Bool
    public let observedFocusStopID: String?
    public let position: VehiclePosition?
    public let basis: Basis

    public init(trip: TrainTrip, stops: [StopTime]? = nil, referenceDate: Date) {
        let calls = stops ?? RailJourneyCalls.combinedSplitCalls(in: trip.stopTimes)
        position = Self.freshPosition(in: trip, at: referenceDate)
        let reported = calls.filter { stop in
            stop.hasConfirmedPassage(at: referenceDate) && !stop.isCancelled
        }
        if let position, let observed = RailRoutePositionEvidence(
            trip: trip, stops: calls, position: position
        ) {
            // A current position before a stop contradicts an older passage flag. Do not
            // combine the flag with GPS to manufacture progress beyond the observed train.
            confirmedPassedStopIDs = observed.passedIDs
            let consistentArrivalReport = calls.last.map { stop in
                guard !stop.isCancelled && stop.hasConfirmedArrival(at: referenceDate) else { return false }
                // A later fix at the terminal agrees with an earlier actual arrival. Only
                // a clearly earlier route position can contradict that historical report.
                guard observed.isClearlyBeforeDestination else { return true }
                return [stop.arrivalObservedAt, stop.hasConfirmedPassage(at: referenceDate) ? stop.passageObservedAt : nil]
                    .compactMap { $0 }.contains {
                        $0 >= position.asOf && $0 <= referenceDate.addingTimeInterval(120)
                    }
            } ?? false
            isArrivalConfirmed = observed.arrived || consistentArrivalReport
            observedFocusStopID = isArrivalConfirmed ? nil : observed.focusID
            basis = .vehiclePosition
        } else {
            confirmedPassedStopIDs = Set(reported.map(\.id))
            isArrivalConfirmed = calls.last.map {
                !$0.isCancelled && $0.hasConfirmedArrival(at: referenceDate)
            } ?? false
            if let last = calls.lastIndex(where: { stop in
                !stop.isCancelled && stop.hasConfirmedArrival(at: referenceDate)
                    && [stop.passageObservedAt, stop.arrivalObservedAt].compactMap { $0 }
                        .contains { referenceDate.timeIntervalSince($0) <= 300 }
            }) {
                observedFocusStopID = calls[last].hasConfirmedPassage(at: referenceDate)
                    ? calls.dropFirst(last + 1).first(where: { !$0.isCancelled })?.id : calls[last].id
            } else {
                observedFocusStopID = nil
            }
            basis = reported.isEmpty && observedFocusStopID == nil && !isArrivalConfirmed ? .unconfirmed : .reportedPassage
        }
    }

    public static func freshPosition(in trip: TrainTrip, at date: Date) -> VehiclePosition? {
        latestRealPosition(in: trip, at: date, maximumAge: 300)
    }

    /// Longer ages may support bounded recovery polling, but must not be called live evidence.
    public static func latestRealPosition(
        in trip: TrainTrip, at date: Date, maximumAge: TimeInterval = 300
    ) -> VehiclePosition? {
        guard date.timeIntervalSinceReferenceDate.isFinite, maximumAge.isFinite, maximumAge >= 0 else { return nil }
        return trip.positions.filter { position in
            let age = date.timeIntervalSince(position.asOf)
            return position.source == .real && position.confidence.isFinite && position.confidence > 0
                && RailRoutePositionEvidence.valid(position.coordinate)
                && age.isFinite && age >= -120 && age <= maximumAge
        }.max { $0.asOf < $1.asOf }
    }
}
