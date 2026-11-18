import Foundation
import TrainTrackerCore

func tripAccessibilitySummary(
    _ trip: TrainTrip,
    timeZoneIdentifier: String? = nil,
    referenceDate: Date = .now,
    lastSuccessfulCheck: Date? = nil,
    lastRefreshFailed: Bool = false,
    selectedSegment: JourneyPlanSegment? = nil,
    guidanceTimeText: String? = nil
) -> String {
    let cardPresentation = ActiveTripCardPresentation(
        trip: trip,
        referenceDate: referenceDate,
        lastSuccessfulCheck: lastSuccessfulCheck,
        lastRefreshFailed: lastRefreshFailed,
        selectedSegment: selectedSegment
    )
    let status = cardPresentation.status
    let origin = cardPresentation.effectiveProgress.stops.first?.station.displayName
        ?? trip.origin?.displayName ?? "unknown origin"
    let destination = cardPresentation.effectiveProgress.stops.last?.station.displayName
        ?? trip.destination?.displayName ?? trip.headsign
    var parts = [
        "\(trip.product), operated by \(trip.operatorName)",
        "from \(origin) to \(destination)",
        "status: \(status.spokenText)",
    ]

    // Before boarding a saved leg, VoiceOver names the boarding station, not the train's next stop.
    if let nextStop = cardPresentation.guidanceStop {
        let label = TripObservationLabels.focus(cardPresentation.effectiveProgress).lowercased()
        parts.append("\(label): \(nextStop.station.displayName)")
        let time = StopTimelineTimePresentation(
            stop: nextStop,
            event: cardPresentation.isBeforeBoarding ? .departure : .arrival,
            timeZoneIdentifier: timeZoneIdentifier
        )
        if let timeText = guidanceTimeText, let event = time.eventNoun {
            parts.append("\(time.timingBasis == .estimated ? "estimated" : "timetable") \(event) at \(timeText)")
        } else if let timeText = time.timeText {
            parts.append("\(time.timingBasis == .estimated ? "estimated" : "timetable time") at \(timeText)")
        }
        // A missing assignment is spoken as missing from the live feed, never as "no platform".
        let platformGuidance = nextStop.platformGuidance(at: referenceDate)
        if case .unavailable = platformGuidance, !trip.capabilities.hasPlatforms {
            // Sources that never report platforms add nothing useful here.
        } else {
            parts.append(platformGuidance.isPredicted
            ? "Roundhouse prediction. \(nextStop.platformSummary(at: referenceDate))"
            : nextStop.platformSummary(at: referenceDate))
        }
    } else if cardPresentation.effectiveProgress.phase == .ended {
        parts.append(cardPresentation.effectiveProgress.evidence.isArrivalConfirmed ? "arrival confirmed" : "arrival unconfirmed")
    }

    parts.append("checked: \(cardPresentation.freshnessValue)")

    return parts.joined(separator: ", ")
}

/// The clock supplies timetable context; only observed evidence supplies arrival and next-call claims.
enum TripObservationLabels {
    static func focus(_ progress: RailJourneyProgress) -> String {
        if progress.evidence.isArrivalConfirmed { return "Arrived" }
        switch progress.phase {
        case .upcoming, .departureSoon: return "Board at"
        case .ended: return "Destination"
        default:
            if progress.evidence.observedFocusStopID != nil { return "Next stop" }
            return progress.timingBasis == .estimated ? "Estimated next stop" : "Timetable next stop"
        }
    }

    static func arrival(_ progress: RailJourneyProgress) -> String {
        // The accompanying clock is a timetable/estimate, even when arrival itself is confirmed.
        if progress.timingBasis == .estimated {
            return progress.phase == .ended ? "Last arrival estimate" : "Estimated arrival"
        }
        return "Timetable arrival"
    }
}
