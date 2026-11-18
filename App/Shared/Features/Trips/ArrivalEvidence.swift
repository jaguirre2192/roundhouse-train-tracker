import Foundation
import TrainTrackerCore

/// Whether anything reports that a train reached a stop, as opposed to the timetable saying it
/// should have by now. The status word "Arrived", the arrival stamp, the kept stub, the
/// "reached" marks in the stop list and on the ticket's line, and the stops-left count all ask
/// here, so none of them turns a timetable that has run out into a claim that the train arrived.
///
/// The answers are Core's: `RailJourneyProgress.evidence`, built from provider passage reports
/// with an observation time and from the train's own fresh, route-matched position. A phone's
/// location is not evidence, and neither is a "passed" flag with no observation behind it.
enum ArrivalEvidence {
    /// True when the train is reported to have reached `stop`.
    static func hasReached(_ stop: StopTime, progress: RailJourneyProgress) -> Bool {
        progress.evidence.confirmedPassedStopIDs.contains(stop.id)
            || (stop.id == progress.stops.last?.id && progress.evidence.isArrivalConfirmed)
    }

    /// True when the train is reported to have reached the end of the rider's journey.
    static func arrivalIsConfirmed(progress: RailJourneyProgress) -> Bool {
        progress.evidence.isArrivalConfirmed
    }

    /// True when the timetable for the rider's journey has run out with nothing reporting the
    /// arrival. The train may simply be late; nothing may be shown as finished.
    static func timetableElapsedUnconfirmed(_ progress: RailJourneyProgress) -> Bool {
        progress.phase == .ended && !progress.isCancelled && !progress.evidence.isArrivalConfirmed
    }

    /// How long after the last known arrival time an unconfirmed journey is left alone before
    /// its stub is kept, in case the train is simply running late.
    static let unconfirmedGrace: TimeInterval = 45 * 60
}
