import SwiftUI
import TrainTrackerCore

struct TripPresentationStatus {
    enum Kind: Equatable {
        case onTime
        case delayed
        case cancelled
        case arrived
        case scheduled
        case estimated
        case unavailable

        /// True when the kind says how the train is running. The others have nothing to say
        /// about that, so the status slot names where the times come from instead.
        var saysHowTheTrainRuns: Bool {
            switch self {
            case .onTime, .delayed, .cancelled, .arrived: true
            case .scheduled, .estimated, .unavailable: false
            }
        }

        var color: Color {
            switch self {
            case .onTime: .ttStatusOnTime
            case .delayed: .ttStatusDelayed
            case .cancelled: .ttStatusCancelled
            case .arrived: .ttRouteActive
            case .scheduled, .estimated, .unavailable: .ttTextSecondary
            }
        }

        var isDisruption: Bool {
            self == .delayed || self == .cancelled
        }
    }

    let kind: Kind
    let delayMinutes: Int
    private let hasComparableEstimate: Bool
    /// True when the arrival is reported, not merely due by the timetable.
    private let isArrivalConfirmed: Bool

    /// How the train is running, in the plain words every surface shares: "On time",
    /// "7 min late", "Canceled", "Arrived". When nothing is known about that, the trust word
    /// for where the times come from stands in ("Timetable", "Estimated"). The two never mix:
    /// there is no "Estimated 7 minutes late".
    var text: String {
        switch kind {
        case .onTime:
            RunningStatusWords.onTime
        case .delayed:
            RunningStatusWords.late(delayMinutes)
        case .cancelled:
            RunningStatusWords.canceled
        case .arrived:
            // "Arrived" needs a report. A timetable that has run out says only that.
            isArrivalConfirmed ? RunningStatusWords.arrived : RunningStatusWords.arrivalUnconfirmed
        case .scheduled:
            JourneyTrust.timetable.title
        case .estimated:
            (hasComparableEstimate ? RunningStatusWords.difference(minutes: delayMinutes) : nil)
                ?? JourneyTrust.estimated.title
        case .unavailable:
            RunningStatusWords.noTimes
        }
    }

    /// The same for speech, with units spelled out: "7 minutes late".
    var spokenText: String {
        switch kind {
        case .delayed, .estimated:
            (hasComparableEstimate ? RunningStatusWords.spokenDifference(minutes: delayMinutes) : nil) ?? text
        default:
            text
        }
    }

    /// True when `text` says how the train is running, including a small difference that is
    /// not counted as a delay.
    var saysHowTheTrainRuns: Bool {
        if kind == .arrived { return isArrivalConfirmed }
        return kind.saysHowTheTrainRuns || (kind == .estimated && hasComparableEstimate && delayMinutes != 0)
    }

    var badgeText: String { text }

    /// The status as a headline. A trust word alone is too bare at that size, so it names
    /// what it describes: "Timetable times".
    var headline: String {
        if saysHowTheTrainRuns { return text }
        return switch kind {
        case .scheduled: "Timetable times"
        case .estimated: "Estimated times"
        default: text
        }
    }
    var color: Color { kind.color }

    /// Status shares the timetable phase and focus with the card. Passage flags alone do not
    /// establish an ended journey or select the stop whose delay matters to this passenger.
    init(trip: TrainTrip, referenceDate: Date = .now, progress: RailJourneyProgress? = nil) {
        let progress = progress ?? RailJourneyProgress(trip: trip, referenceDate: referenceDate)
        let focus = progress.phase == .unavailable ? trip.nextStop : progress.focusStop
        let event: StopTimelineTimePresentation.Event =
            progress.phase == .underway && focus?.id == progress.stops.last?.id ? .arrival : .departure
        let timing = focus.map { StopTimelineTimePresentation(stop: $0, event: event) }
        hasComparableEstimate = timing?.delayMinutes != nil
        isArrivalConfirmed = progress.phase == .ended && ArrivalEvidence.arrivalIsConfirmed(progress: progress)
        delayMinutes = timing?.delayMinutes ?? 0

        if trip.stopTimes.isEmpty {
            kind = .unavailable
        } else if trip.isCancelled || progress.isCancelled {
            kind = .cancelled
        } else if progress.phase == .ended {
            kind = .arrived
        } else if hasComparableEstimate, delayMinutes >= 5 {
            kind = .delayed
        } else if hasComparableEstimate, delayMinutes == 0 {
            kind = .onTime
        } else if timing?.timingBasis == .estimated {
            kind = .estimated
        } else if timing?.timingBasis == .scheduled {
            kind = .scheduled
        } else {
            kind = .unavailable
        }
    }
}
