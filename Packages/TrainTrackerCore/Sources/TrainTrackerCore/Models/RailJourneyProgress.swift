import Foundation

/// Time-based journey context, not evidence that a passenger boarded or a train arrived.
/// Observation evidence is separate; a fresh matched vehicle fix can constrain clock estimates.
public struct RailJourneyProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case upcoming
        case departureSoon
        case underway
        case ended
        case unavailable
    }

    public enum TimingBasis: String, Equatable, Sendable {
        case scheduled
        case estimated
    }

    public let phase: Phase
    /// The time evidence used for the current phase and focused stop; never a freshness claim.
    public let timingBasis: TimingBasis
    /// The selected journey's calls, combining compatible adjacent split arrival/departure rows.
    /// Invalid or ambiguous selections produce an empty array.
    public let stops: [StopTime]
    /// The boarding stop before departure, then the next noncancelled stop by effective time.
    /// A stop remains focused during its scheduled/estimated dwell. Ended journeys have no focus.
    public let focusStop: StopTime?
    public let departureDate: Date?
    public let arrivalDate: Date?
    /// The next phase or focused-stop boundary, if known and later than the reference date.
    public let nextTransitionDate: Date?
    public let isCancelled: Bool
    public let evidence: RailJourneyEvidence

    public init(
        trip: TrainTrip,
        referenceDate: Date,
        boardingStationID: RailIdentifier? = nil,
        alightingStationID: RailIdentifier? = nil
    ) {
        let selected = Self.selectedStops(
            in: RailJourneyCalls.combinedSplitCalls(in: trip.stopTimes),
            boardingStationID: boardingStationID,
            alightingStationID: alightingStationID
        )
        self.init(selected: selected, trip: trip, referenceDate: referenceDate)
    }

    /// Selects a passenger leg from provider-independent journey places. Journey-search place IDs
    /// can differ from the IDs in a subsequently resolved train, so exact IDs are preferred and a
    /// unique, close station-location match is accepted as a bounded fallback.
    public init(
        trip: TrainTrip,
        referenceDate: Date,
        boardingPlace: RailPlace,
        alightingPlace: RailPlace
    ) {
        let selected = Self.selectedStops(
            in: RailJourneyCalls.combinedSplitCalls(in: trip.stopTimes),
            boardingPlace: boardingPlace,
            alightingPlace: alightingPlace
        )
        self.init(selected: selected, trip: trip, referenceDate: referenceDate)
    }

    private init(selected: [StopTime], trip: TrainTrip, referenceDate: Date) {
        stops = selected
        evidence = RailJourneyEvidence(trip: trip, stops: selected, referenceDate: referenceDate)
        let departure = selected.first.flatMap(Self.departureTime)
        let arrival = selected.last.flatMap(Self.arrivalTime)
        departureDate = departure?.date
        arrivalDate = arrival?.date
        isCancelled = !selected.isEmpty && selected.allSatisfy(\.isCancelled)

        guard selected.count >= 2,
              !isCancelled,
              let departure, let arrival,
              arrival.date >= departure.date,
              referenceDate.timeIntervalSinceReferenceDate.isFinite else {
            phase = .unavailable
            timingBasis = Self.basis([departure, arrival])
            focusStop = nil
            nextTransitionDate = nil
            return
        }

        let departureSoon = departure.date.addingTimeInterval(-30 * 60)
        if referenceDate < departure.date {
            phase = referenceDate < departureSoon ? .upcoming : .departureSoon
            timingBasis = departure.basis
            // A cancelled boarding call does not imply boarding at a different station.
            focusStop = selected.first.flatMap { $0.isCancelled ? nil : $0 }
            nextTransitionDate = referenceDate < departureSoon ? departureSoon : departure.date
        } else if evidence.isArrivalConfirmed {
            phase = .ended
            timingBasis = arrival.basis
            focusStop = nil
            nextTransitionDate = nil
        } else if let focusID = evidence.observedFocusStopID,
                  let observedFocus = selected.first(where: { $0.id == focusID }) {
            phase = .underway
            focusStop = observedFocus
            timingBasis = Self.basis([departure, arrival, Self.arrivalTime(observedFocus)])
            let expiry = evidence.position?.asOf.addingTimeInterval(300)
            nextTransitionDate = expiry.flatMap { $0 > referenceDate ? $0 : nil }
        } else if referenceDate >= arrival.date {
            phase = .ended
            timingBasis = arrival.basis
            focusStop = nil
            nextTransitionDate = nil
        } else {
            phase = .underway
            let next = selected.indices.dropFirst().compactMap { index -> (StopTime, Timing)? in
                let stop = selected[index]
                guard !stop.isCancelled,
                      let time = index == selected.endIndex - 1
                        ? Self.arrivalTime(stop) : Self.departureTime(stop),
                      time.date > referenceDate else { return nil }
                return (stop, time)
            }.first
            focusStop = next?.0
            timingBasis = Self.basis([departure, arrival, next?.1])
            nextTransitionDate = min(next?.1.date ?? arrival.date, arrival.date)
        }
    }

    private struct Timing {
        let date: Date
        let basis: TimingBasis
    }

    private static func departureTime(_ stop: StopTime) -> Timing? {
        timing(
            expected: stop.expectedDeparture,
            scheduled: stop.scheduledDeparture,
            fallbackExpected: stop.expectedArrival,
            fallbackScheduled: stop.scheduledArrival
        )
    }

    private static func arrivalTime(_ stop: StopTime) -> Timing? {
        timing(
            expected: stop.expectedArrival,
            scheduled: stop.scheduledArrival,
            fallbackExpected: stop.expectedDeparture,
            fallbackScheduled: stop.scheduledDeparture
        )
    }

    private static func timing(
        expected: Date?, scheduled: Date?, fallbackExpected: Date?, fallbackScheduled: Date?
    ) -> Timing? {
        let candidates: [(Date?, TimingBasis)] = [
            (expected, .estimated), (scheduled, .scheduled),
            (fallbackExpected, .estimated), (fallbackScheduled, .scheduled),
        ]
        guard let (date, basis) = candidates.first(where: { $0.0 != nil }),
              let date, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return Timing(date: date, basis: basis)
    }

    private static func basis(_ timings: [Timing?]) -> TimingBasis {
        timings.contains { $0?.basis == .estimated } ? .estimated : .scheduled
    }

    private static func selectedStops(
        in stops: [StopTime],
        boardingStationID: RailIdentifier?,
        alightingStationID: RailIdentifier?
    ) -> [StopTime] {
        guard !stops.isEmpty,
              let boardingIndex = selectedIndex(
                boardingStationID, in: stops, fallback: stops.startIndex
              ),
              let alightingIndex = selectedIndex(
                alightingStationID, in: stops, fallback: stops.endIndex - 1
              ),
              boardingIndex < alightingIndex else { return [] }
        return Array(stops[boardingIndex...alightingIndex])
    }

    private static func selectedStops(
        in stops: [StopTime],
        boardingPlace: RailPlace,
        alightingPlace: RailPlace
    ) -> [StopTime] {
        guard !stops.isEmpty,
              let boardingIndex = selectedIndex(boardingPlace, in: stops),
              let alightingIndex = selectedIndex(alightingPlace, in: stops),
              boardingIndex < alightingIndex else { return [] }
        return Array(stops[boardingIndex...alightingIndex])
    }

    private static func selectedIndex(
        _ stationID: RailIdentifier?, in stops: [StopTime], fallback: Int
    ) -> Int? {
        guard let stationID else { return fallback }
        let matches = stops.indices.filter { stops[$0].station.id == stationID }
        // Station IDs alone cannot distinguish repeated calls on a loop service.
        return matches.count == 1 ? matches.first : nil
    }

    private static func selectedIndex(_ place: RailPlace, in stops: [StopTime]) -> Int? {
        guard place.kind == .station else { return nil }
        let backendStationID: RailIdentifier?
        if place.id.rawValue.hasPrefix("rail:") {
            guard let identifier = BackendRailPlaceStationIdentity.stationID(for: place.id) else { return nil }
            backendStationID = identifier
        } else {
            backendStationID = nil
        }
        let exactMatches = stops.indices.filter { stops[$0].station.id == place.id }
        if !exactMatches.isEmpty {
            return exactMatches.count == 1 ? exactMatches.first : nil
        }
        if let backendStationID {
            let nativeMatches = stops.indices.filter { stops[$0].station.id == backendStationID }
            // An exact provider/native ID survives country/coordinate corrections, but cannot
            // distinguish repeated station calls. Never let geography break that ambiguity.
            if !nativeMatches.isEmpty { return nativeMatches.count == 1 ? nativeMatches.first : nil }
        }

        guard !place.countryCode.isEmpty,
              place.location.latitude != 0 || place.location.longitude != 0 else { return nil }
        let locationMatches = stops.indices.filter { index in
            let station = stops[index].station
            guard station.countryCode.caseInsensitiveCompare(place.countryCode) == .orderedSame,
                  station.location.latitude != 0 || station.location.longitude != 0 else {
                return false
            }
            // About 55 m of latitude. Requiring one match prevents nearby platforms or repeated
            // calls from silently selecting an arbitrary stop.
            return abs(station.location.latitude - place.location.latitude) < 0.0005
                && abs(station.location.longitude - place.location.longitude) < 0.0005
        }
        return locationMatches.count == 1 ? locationMatches.first : nil
    }
}
