import Foundation
import TrainTrackerCore

struct JourneyOptionEndpointDates: Equatable {
    let departure: Date
    let arrival: Date

    init(option: JourneyOption) {
        let railSegments = option.segments.compactMap { segment -> RailJourneySegment? in
            guard case let .rail(rail) = segment else { return nil }
            return rail
        }
        departure = railSegments.first?.from.expectedDeparture
            ?? railSegments.first?.from.scheduledDeparture
            ?? option.startTime
        arrival = railSegments.last?.to.expectedArrival
            ?? railSegments.last?.to.scheduledArrival
            ?? option.endTime
    }
}

extension JourneyOption {
    var effectiveEndpointDates: JourneyOptionEndpointDates {
        JourneyOptionEndpointDates(option: self)
    }
}
