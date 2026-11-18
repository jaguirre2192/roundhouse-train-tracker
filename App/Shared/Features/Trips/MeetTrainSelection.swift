import Foundation
import TrainTrackerCore

/// A booked leg selects the passenger's stop, including intermediate alightings. A standalone
/// train asks the rider to choose one explicitly. Never assume the train's terminus is theirs.
struct MeetTrainSelection {
    let calls: [StopTime]
    let bookedCall: StopTime?

    init(trip: TrainTrip, segment: JourneyPlanSegment?, watching: Bool, at now: Date) {
        let calls = RailJourneyProgress(trip: trip, referenceDate: now).stops
        func canMeet(_ stop: StopTime) -> Bool {
            guard !watching, !trip.isCancelled, !stop.isCancelled, !stop.hasConfirmedArrival(at: now),
                  let latest = [stop.expectedArrival, stop.scheduledArrival].compactMap({ $0 }).max() else { return false }
            return latest.addingTimeInterval(12 * 3_600) > now
        }
        if let segment {
            let section = RailJourneyProgress(trip: trip, referenceDate: now,
                                              boardingPlace: segment.from, alightingPlace: segment.to)
            bookedCall = section.stops.last.flatMap { canMeet($0) ? $0 : nil }
            self.calls = bookedCall.map { [$0] } ?? []
        } else {
            bookedCall = nil
            self.calls = Array(calls.dropFirst().filter(canMeet))
        }
    }

    static func timeLabel(_ date: Date, zone: TimeZone?) -> String {
        var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        format.timeZone = zone ?? .gmt
        let zoneName = zone?.localizedName(for: zone?.isDaylightSavingTime(for: date) == true ? .shortDaylightSaving : .shortStandard,
                                           locale: .autoupdatingCurrent) ?? "UTC"
        return date.formatted(format) + " " + zoneName
    }
}
