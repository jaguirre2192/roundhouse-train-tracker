import Foundation
import TrainTrackerCore

/// Selects itinerary context from time and saved leg order, never from passenger presence.
struct JourneyPlanStage: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case rail
        case connection
        case walk
        case untracked
        case legacy
    }

    struct Connection: Equatable, Sendable {
        let previous: JourneyPlanSegment
        let next: JourneyPlanSegment
        let walks: [JourneyPlanSegment]
        /// The selected timetable interval, not a minimum or a feasibility assessment.
        let timetableMinutes: Int?
        /// Present only when an endpoint uses an estimate; freshness remains a separate concern.
        let estimatedMinutes: Int?
        /// Saved walking time between the trains, rounded up; zero for a same-station change.
        var walkMinutes: Int = 0
        var timetable: ConnectionTimetable?

        /// The last estimate leaves no time at all before the onward departure.
        var isMissed: Bool { (estimatedMinutes ?? 1) <= 0 }

        /// Roundhouse's planning allowance, not a published minimum connection time.
        static func planningAllowance(walkingSeconds: TimeInterval) -> TimeInterval {
            max(300, ceil(walkingSeconds / 60) * 60 + 180)
        }

        var isTight: Bool {
            guard let estimated = estimatedMinutes, estimated > 0 else { return false }
            if let published = timetable?.published { return estimated < published.minutes }
            if let timetable, timetable.planningMinutes == nil { return false }
            return Double(estimated) * 60 < Self.planningAllowance(walkingSeconds: Double(walkMinutes) * 60) && estimated < (timetableMinutes ?? .max)
        }
    }

    let direction: JourneyPlanDirection
    let directionTitle: String
    let focusSegment: JourneyPlanSegment?
    let focusTrip: TrainTrip?
    /// For `.connection`, this describes the active transfer window. Other kinds may carry
    /// a retained risk advisory; their focus still describes the current itinerary leg.
    let connection: Connection?
    let kind: Kind
    /// A fresh vehicle/stop observation still places the train before the selected alighting call.
    let hasObservedUnfinishedJourney: Bool

    init(plan: TrackedJourneyPlan, trips: [TrainTrip], referenceDate: Date) {
        let tripsByID = Dictionary(grouping: trips, by: \.id)
        let outbound = Self.states(for: plan.outbound, tripsByID: tripsByID, at: referenceDate)
        // A late incoming leg can outlast the final train's unchanged timetable.
        // Cancelled/missing legs retain the saved bound instead of inventing completion.
        let outboundEnd = outbound.compactMap { $0.usableProgress?.arrivalDate }
            .reduce(plan.outbound.arrival, max)
        let selected: [SegmentState]
        let outboundIsObserved = outbound.contains { $0.hasObservedUnfinishedJourney }
            || Self.observedLegacyDirection(plan.outbound, tripsByID: tripsByID, at: referenceDate)
        if let returnDirection = plan.returnDirection, referenceDate >= outboundEnd, !outboundIsObserved {
            direction = returnDirection
            directionTitle = JourneySearchCopy.returnDirection
            selected = Self.states(for: returnDirection, tripsByID: tripsByID, at: referenceDate)
        } else {
            direction = plan.outbound
            directionTitle = JourneySearchCopy.outbound
            selected = outbound
        }

        hasObservedUnfinishedJourney = selected.contains { $0.hasObservedUnfinishedJourney }
            || Self.observedLegacyDirection(direction, tripsByID: tripsByID, at: referenceDate)

        guard direction.selectedSegments != nil else {
            kind = .legacy
            focusSegment = nil
            focusTrip = nil
            connection = nil
            return
        }
        guard !selected.isEmpty else {
            kind = .untracked
            focusSegment = nil
            focusTrip = nil
            connection = nil
            return
        }

        // Unknown legs remain in order. They cannot be silently skipped in favour of a train.
        let index = selected.indices.first { index in
            Self.selectionEnd(at: index, in: selected).map { referenceDate < $0 } ?? true
        } ?? selected.endIndex - 1
        let risk = Self.connectionRisk(in: selected)
        if risk == nil, let transfer = Self.connection(around: index, in: selected, at: referenceDate) {
            kind = .connection
            connection = transfer.value
            focusSegment = selected[transfer.nextIndex].segment
            focusTrip = selected[transfer.nextIndex].trip
        } else {
            let focus = selected[index]
            kind = focus.segment.kind == .walk ? .walk : (focus.trip == nil ? .untracked : .rail)
            focusSegment = focus.segment
            focusTrip = focus.trip
            connection = risk ?? Self.tightConnection(in: selected, at: referenceDate)
        }
    }

    private struct SegmentState {
        let segment: JourneyPlanSegment
        let trip: TrainTrip?
        let progress: RailJourneyProgress?

        var usableProgress: RailJourneyProgress? {
            guard let progress, progress.phase != .unavailable,
                  progress.stops.first?.isCancelled == false,
                  progress.stops.last?.isCancelled == false else { return nil }
            return progress
        }

        var hasObservedUnfinishedJourney: Bool {
            guard let progress = usableProgress else { return false }
            return progress.phase == .underway && !progress.evidence.isArrivalConfirmed
                && progress.evidence.observedFocusStopID != nil
        }

        var scheduledDeparture: Date? {
            segment.departure ?? progress?.stops.first?.scheduledDeparture
                ?? progress?.stops.first?.scheduledArrival
        }

        var scheduledArrival: Date? {
            segment.arrival ?? progress?.stops.last?.scheduledArrival
                ?? progress?.stops.last?.scheduledDeparture
        }

        var departure: Date? { usableProgress?.departureDate ?? scheduledDeparture }
        var arrival: Date? { usableProgress?.arrivalDate ?? scheduledArrival }

        var usesEstimatedDeparture: Bool {
            guard let stop = usableProgress?.stops.first else { return false }
            return stop.expectedDeparture != nil || (stop.scheduledDeparture == nil && stop.expectedArrival != nil)
        }

        var usesEstimatedArrival: Bool {
            guard let stop = usableProgress?.stops.last else { return false }
            return stop.expectedArrival != nil || (stop.scheduledArrival == nil && stop.expectedDeparture != nil)
        }
    }

    private static func states(
        for direction: JourneyPlanDirection,
        tripsByID: [RailIdentifier: [TrainTrip]],
        at referenceDate: Date
    ) -> [SegmentState] {
        let segments = direction.selectedSegments ?? []
        let segmentsByID = Dictionary(grouping: segments, by: \.id)
        let ambiguousTripIDs = direction.ambiguousTripIDs
        let childTripIDs = Set(direction.childTripIDs)
        return segments.map { segment in
            guard segment.kind == .rail,
                  segmentsByID[segment.id]?.count == 1,
                  segment.unavailableReason == nil,
                  let tripID = segment.resolvedTripID,
                  childTripIDs.contains(tripID),
                  !ambiguousTripIDs.contains(tripID),
                  let matches = tripsByID[tripID], matches.count == 1,
                  let trip = matches.first else {
                return SegmentState(segment: segment, trip: nil, progress: nil)
            }
            let progress = RailJourneyProgress(
                trip: trip, referenceDate: referenceDate,
                boardingPlace: segment.from, alightingPlace: segment.to
            )
            guard !progress.stops.isEmpty else {
                return SegmentState(segment: segment, trip: nil, progress: nil)
            }
            return SegmentState(segment: segment, trip: trip, progress: progress)
        }
    }

    private static func observedLegacyDirection(
        _ direction: JourneyPlanDirection, tripsByID: [RailIdentifier: [TrainTrip]], at date: Date
    ) -> Bool {
        guard direction.selectedSegments == nil else { return false }
        return direction.childTripIDs.contains { id in
            guard let matches = tripsByID[id], matches.count == 1, let trip = matches.first else { return false }
            let progress = RailJourneyProgress(trip: trip, referenceDate: date)
            return !progress.isCancelled && progress.phase == .underway
                && !progress.evidence.isArrivalConfirmed && progress.evidence.observedFocusStopID != nil
        }
    }

    private static func selectionEnd(at index: Int, in states: [SegmentState]) -> Date? {
        if states[index].hasObservedUnfinishedJourney { return nil }
        if let arrival = states[index].arrival { return arrival }
        guard states[index].segment.kind == .walk else { return nil }
        // For an untimed walk, a linked onward departure bounds its place in the timetable.
        // This does not assert that the walk happened, or synthesize a walking arrival time.
        var station = states[index].segment.to
        for next in states.dropFirst(index + 1) {
            guard JourneyTransferStation.matches(next.segment.from, station) else { return nil }
            if next.segment.kind == .rail { return next.departure }
            station = next.segment.to
        }
        return nil
    }

    private static func connection(
        around index: Int, in states: [SegmentState], at referenceDate: Date
    ) -> (value: Connection, nextIndex: Int)? {
        let previousIndex: Int?
        let nextIndex: Int?
        if states[index].segment.kind == .rail {
            previousIndex = states.indices.prefix(index).last { states[$0].segment.kind == .rail }
            nextIndex = index
        } else {
            previousIndex = states.indices.prefix(index).last { states[$0].segment.kind == .rail }
            nextIndex = states.indices.dropFirst(index + 1).first { states[$0].segment.kind == .rail }
        }
        guard let previousIndex, let nextIndex,
              previousIndex < nextIndex else { return nil }
        guard let transfer = transfer(previous: previousIndex, next: nextIndex, in: states),
              referenceDate >= transfer.arrival, referenceDate < transfer.departure else { return nil }
        return (transfer.value, nextIndex)
    }

    private static func connectionRisk(in states: [SegmentState]) -> Connection? {
        let rails = states.indices.filter { states[$0].segment.kind == .rail }
        for (previous, next) in zip(rails, rails.dropFirst()) {
            guard let transfer = transfer(previous: previous, next: next, in: states),
                  transfer.value.estimatedMinutes != nil,
                  transfer.arrival >= transfer.departure else { continue }
            // Keep this advisory even after the onward departure or incoming arrival.
            // An elapsed estimate is not evidence that this connection was made.
            return transfer.value
        }
        return nil
    }

    /// Unlike a missed connection, a tight one is only worth raising until the onward train leaves.
    private static func tightConnection(in states: [SegmentState], at referenceDate: Date) -> Connection? {
        let rails = states.indices.filter { states[$0].segment.kind == .rail }
        for (previous, next) in zip(rails, rails.dropFirst()) {
            guard let transfer = transfer(previous: previous, next: next, in: states),
                  transfer.value.isTight, referenceDate < transfer.departure else { continue }
            return transfer.value
        }
        return nil
    }

    private struct Transfer {
        let value: Connection
        let arrival: Date
        let departure: Date
    }

    private static func transfer(
        previous previousIndex: Int, next nextIndex: Int, in states: [SegmentState]
    ) -> Transfer? {
        let previous = states[previousIndex]
        let next = states[nextIndex]
        let walks = states[(previousIndex + 1)..<nextIndex].map(\.segment)
        guard previous.usableProgress != nil, next.usableProgress != nil,
              linked(previous: previous.segment, walks: walks, next: next.segment),
              let arrival = previous.arrival, let departure = next.departure else { return nil }

        let hasEstimate = previous.usesEstimatedArrival || next.usesEstimatedDeparture
        let timetable = ConnectionTimetable(previous: previous.segment, next: next.segment, walks: walks,
            arrival: previous.usableProgress?.stops.last, departure: next.usableProgress?.stops.first)
        let walking = ConnectionTimetable.walkingSeconds(walks).flatMap { Int(exactly: ceil($0 / 60)) }
        return Transfer(
            value: Connection(
                previous: previous.segment, next: next.segment, walks: walks,
                timetableMinutes: minutes(from: previous.scheduledArrival, to: next.scheduledDeparture),
                estimatedMinutes: hasEstimate ? minutes(from: arrival, to: departure) : nil,
                walkMinutes: walking ?? 0, timetable: timetable
            ),
            arrival: arrival, departure: departure
        )
    }

    private static func linked(
        previous: JourneyPlanSegment, walks: [JourneyPlanSegment], next: JourneyPlanSegment
    ) -> Bool {
        let segments = [previous] + walks + [next]
        guard Set(segments.map(\.id)).count == segments.count else { return false }
        var station = previous.to
        for walk in walks {
            guard walk.kind == .walk, JourneyTransferStation.matches(walk.from, station) else { return false }
            station = walk.to
        }
        return JourneyTransferStation.matches(station, next.from)
    }

    private static func minutes(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let interval = end.timeIntervalSince(start) / 60
        guard interval.isFinite, interval > Double(Int.min), interval < Double(Int.max) else { return nil }
        return Int(interval)
    }
}
