import Foundation
import TrainTrackerCore

/// The new header describes one focused stop and one event, independent of broader card status.
struct JourneyTrackingHeaderPresentation {
    let experience: JourneyExperiencePresentation

    var platformValue: String? {
        switch guidance {
        case .unavailable: nil
        case .positioning:
            guidance.summaryText(noun: experience.platformNoun, source: experience.platformSourceName)
        case .likelyPlatform, .official:
            guidance.metricValue
        }
    }

    var platformLabel: String {
        switch guidance {
        case .positioning: "Roundhouse prediction"
        case .likelyPlatform: "\(experience.platformNoun) · prediction"
        case let .official(_, source, changed):
            [
                changed ? "\(experience.platformNoun) changed"
                    : source == .scheduled ? "Scheduled \(experience.platformNoun.lowercased())" : experience.platformNoun,
                experience.platformSourceName.map { "via \($0)" },
            ].compactMap { $0 }.joined(separator: " · ")
        case .unavailable: ""
        }
    }

    var platformAccessibilityText: String {
        let summary = guidance.summaryText(noun: experience.platformNoun, source: experience.platformSourceName)
        return guidance.isPredicted ? "Roundhouse prediction. \(summary)" : summary
    }

    var isPlatformPredicted: Bool { guidance.isPredicted }
    var isPlatformChanged: Bool { guidance.isOfficialChange }
    var statusText: String { status.text }
    var statusKind: TripPresentationStatus.Kind { status.kind }

    private var guidance: PlatformGuidance {
        guard experience.progress.phase != .unavailable else { return .unavailable }
        // The experience suppresses assignments for cancelled passenger boundaries and ended trips.
        return experience.platformGuidance
    }

    private var status: (kind: TripPresentationStatus.Kind, text: String) {
        let progress = experience.progress
        if experience.trip.stopTimes.isEmpty { return (.unavailable, RunningStatusWords.noTimes) }
        if progress.isCancelled || experience.trip.isCancelled {
            return (.cancelled, RunningStatusWords.canceled)
        }
        if experience.hasCancelledBoundary { return (.cancelled, "Stop canceled") }
        if progress.phase == .ended {
            return (.arrived, progress.evidence.isArrivalConfirmed
                ? RunningStatusWords.arrived : RunningStatusWords.arrivalUnconfirmed)
        }
        guard progress.phase != .unavailable, let stop = progress.focusStop else {
            return (.unavailable, RunningStatusWords.noTimes)
        }
        let event: StopTimelineTimePresentation.Event =
            progress.phase == .upcoming || progress.phase == .departureSoon ? .departure : .arrival
        let timing = StopTimelineTimePresentation(stop: stop, event: event)
        if let delay = timing.delayMinutes, delay >= 5 {
            return (.delayed, RunningStatusWords.late(delay))
        }
        if timing.delayMinutes == 0 { return (.onTime, RunningStatusWords.onTime) }
        if timing.timingBasis == .estimated {
            return (.estimated, timing.delayMinutes.flatMap { RunningStatusWords.difference(minutes: $0) }
                ?? "Estimated times")
        }
        if timing.timingBasis == .scheduled { return (.scheduled, experience.unreportedScheduledStopText ?? "Timetable times") }
        return (.unavailable, RunningStatusWords.noTimes)
    }
}
