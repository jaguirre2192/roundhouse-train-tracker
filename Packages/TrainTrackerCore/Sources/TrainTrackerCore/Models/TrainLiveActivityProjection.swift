import Foundation

/// Pure selection and freshness policy for one explicitly selected rail leg.
/// The coordinator separately enforces removal, authorization and the eight-hour lifetime cap.
public struct TrainLiveActivityProjection: Equatable, Sendable {
    public enum Eligibility: Equatable, Sendable {
        case available
        case tooEarly(Date)
        case ended
        case cancelled
        case unavailable
    }

    public let state: TrainLiveActivityState
    public let eligibility: Eligibility
    public let nextTransitionDate: Date?
    public let shouldEnd: Bool

    public init(
        trip: TrainTrip,
        referenceDate: Date,
        boardingStationID: RailIdentifier? = nil,
        alightingStationID: RailIdentifier? = nil,
        stationTimeZones: [RailIdentifier: String] = [:],
        lastSuccessfulCheck: Date? = nil,
        refreshFailed: Bool = false
    ) {
        let progress = RailJourneyProgress(
            trip: trip, referenceDate: referenceDate,
            boardingStationID: boardingStationID, alightingStationID: alightingStationID
        )
        let now = Self.timestamp(referenceDate) ?? 0
        let checkedAt = lastSuccessfulCheck.flatMap(Self.timestamp).flatMap { $0 <= now ? $0 : nil }
        let freshSuccess = !refreshFailed && checkedAt.map { now < $0 + 300 } == true
        let departure = progress.departureDate.flatMap(Self.timestamp)
        let arrival = progress.arrivalDate.flatMap(Self.timestamp)
        let cancelledStop = progress.stops.first.flatMap { $0.isCancelled ? $0 : nil }
            ?? progress.stops.last.flatMap { $0.isCancelled ? $0 : nil }
        let selectedCancellation = progress.stops.count >= 2 && cancelledStop != nil
        let validWindow = Self.timestamp(referenceDate) != nil && progress.phase != .unavailable
            && departure != nil && arrival != nil
        let phase: TrainLiveActivityState.Phase
        let focus: StopTime?
        let event: Timing?
        var transitions: [Double] = []
        var unconfirmedElapsedArrival = false

        if selectedCancellation {
            phase = .cancelled
            eligibility = .cancelled
            shouldEnd = true
            focus = cancelledStop
            event = focus.flatMap { Self.timing($0, departure: $0.id == progress.stops.first?.id) }
        } else if !validWindow {
            phase = .unavailable
            eligibility = .unavailable
            shouldEnd = false
            focus = nil
            event = nil
        } else {
            if progress.phase == .ended {
                if progress.evidence.isArrivalConfirmed {
                    phase = .ended
                } else if progress.evidence.position != nil || progress.evidence.observedFocusStopID != nil {
                    phase = .underway
                } else {
                    phase = .unavailable
                    unconfirmedElapsedArrival = true
                }
            } else {
                phase = Self.phase(progress.phase)
            }
            let usesDeparture = phase == .upcoming || phase == .departureSoon
            let observedFocus = progress.stops.first { $0.id == progress.evidence.observedFocusStopID }
            switch phase {
            case .upcoming, .departureSoon: focus = progress.stops.first
            case .ended: focus = progress.stops.last
            case .unavailable: focus = nil
            default:
                focus = observedFocus ?? (progress.phase == .ended ? progress.stops.last : progress.focusStop)
            }
            event = focus.flatMap { Self.timing($0, departure: usesDeparture) }
            if phase == .ended {
                eligibility = .ended
                // Observation time is when the feed reported the status, not the arrival
                // event itself. Repeated status updates must not restart this grace.
                let recoveryEnd = (arrival ?? now) + 1_800
                shouldEnd = freshSuccess && now >= recoveryEnd
                transitions.append(recoveryEnd)
            } else if phase == .unavailable {
                eligibility = .unavailable
                shouldEnd = false
            } else {
                let eligibleAt = (departure ?? now) - 3_600
                eligibility = now < eligibleAt ? .tooEarly(Date(timeIntervalSince1970: eligibleAt)) : .available
                shouldEnd = false
                transitions.append(eligibleAt)
                if progress.phase == .ended, let position = progress.evidence.position {
                    transitions.append(position.asOf.timeIntervalSince1970 + 300)
                }
            }
            if let transition = progress.nextTransitionDate.flatMap(Self.timestamp) {
                transitions.append(transition)
            }
        }

        let platform = Self.platform(focus, referenceDate: referenceDate)
        if let expiry = platform.expiresAt { transitions.append(expiry) }
        let next = transitions.filter { $0 > now }.min()
        nextTransitionDate = next.map { Date(timeIntervalSince1970: $0) }
        var validUntil = min(checkedAt.map { $0 + 300 } ?? now, next ?? .greatestFiniteMagnitude)
        if platform.basis == .reported, let reported = (focus?.platformObservedAt ?? trip.sourceFetchedAt).flatMap(Self.timestamp) {
            validUntil = min(validUntil, reported <= now ? reported + 300 : now)
        }
        if refreshFailed || checkedAt == nil || unconfirmedElapsedArrival { validUntil = min(validUntil, now) }
        let boarding = progress.stops.first
        let isBoardingAssignment = (phase == .upcoming || phase == .departureSoon) && platform.basis == .reported && focus?.id == boarding?.id
            && (boarding?.expectedDeparture ?? boarding?.scheduledDeparture) != nil
            && !progress.evidence.isArrivalConfirmed && progress.evidence.confirmedPassedStopIDs.isEmpty
        state = TrainLiveActivityState(
            phase: phase,
            focusName: focus?.station.displayName ?? "Journey details unavailable",
            eventTime: event?.timestamp,
            timeZoneIdentifier: focus.flatMap { stationTimeZones[$0.station.id] },
            timingBasis: event?.basis ?? .unavailable,
            platform: platform.value,
            platformBasis: platform.basis,
            platformChanged: platform.changed,
            delayMinutes: event?.delayMinutes,
            checkedAt: checkedAt,
            validUntil: validUntil,
            isStopCancelled: selectedCancellation && !progress.isCancelled,
            platformKind: focus?.platformKind,
            platformSource: focus?.platformSource,
            boardingPlatformSequence: isBoardingAssignment ? boarding?.sequence : nil
        )
    }

    private struct Timing {
        let timestamp: Double
        let basis: TrainLiveActivityState.TimingBasis
        let delayMinutes: Int?
    }

    private static func timing(_ stop: StopTime, departure: Bool) -> Timing? {
        let preferredExpected = departure ? stop.expectedDeparture : stop.expectedArrival
        let preferredScheduled = departure ? stop.scheduledDeparture : stop.scheduledArrival
        let fallbackExpected = departure ? stop.expectedArrival : stop.expectedDeparture
        let fallbackScheduled = departure ? stop.scheduledArrival : stop.scheduledDeparture
        let candidates: [(Date?, TrainLiveActivityState.TimingBasis, Date?)] = [
            (preferredExpected, .estimated, preferredScheduled),
            (preferredScheduled, .scheduled, nil),
            (fallbackExpected, .estimated, fallbackScheduled),
            (fallbackScheduled, .scheduled, nil),
        ]
        guard let candidate = candidates.first(where: { $0.0 != nil }),
              let date = candidate.0, let time = timestamp(date) else { return nil }
        // Pair like events, never an expected arrival with a scheduled departure.
        let delay = candidate.2.flatMap(timestamp).map { Int((time - $0) / 60) }
        return Timing(timestamp: time, basis: candidate.1, delayMinutes: delay)
    }

    private struct Platform {
        let value: String?
        let basis: TrainLiveActivityState.PlatformBasis
        let changed: Bool
        let expiresAt: Double?

        static let unavailable = Platform(value: nil, basis: .unavailable, changed: false, expiresAt: nil)
    }

    private static func platform(_ stop: StopTime?, referenceDate: Date) -> Platform {
        guard let stop else { return .unavailable }
        switch stop.platformGuidance(at: referenceDate) {
        case let .official(platform, source, changed):
            return Platform(
                value: platform, basis: source == .current ? .reported : .scheduled,
                changed: changed, expiresAt: nil
            )
        case let .likelyPlatform(platform, _, _, _):
            guard let forecast = stop.platformForecast,
                  let generatedAt = timestamp(forecast.generatedAt),
                  let now = timestamp(referenceDate), generatedAt <= now,
                  let expiry = timestamp(forecast.expiresAt) else {
                return .unavailable
            }
            return Platform(value: platform, basis: .predicted, changed: false, expiresAt: expiry)
        case .positioning, .unavailable:
            // A positioning zone cannot safely be rendered as an exact platform.
            return .unavailable
        }
    }

    private static func timestamp(_ date: Date) -> Double? {
        TrainLiveActivityState.safeTimestamp(date.timeIntervalSince1970)
    }

    private static func phase(_ phase: RailJourneyProgress.Phase) -> TrainLiveActivityState.Phase {
        switch phase {
        case .upcoming: .upcoming
        case .departureSoon: .departureSoon
        case .underway: .underway
        case .ended: .ended
        case .unavailable: .unavailable
        }
    }
}
