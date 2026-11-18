import Foundation
import TrainTrackerCore

struct JourneySearchFormState: Equatable {
    var origin: RailPlace?
    var destination: RailPlace?
    var outboundTime: Date
    var outboundArriveBy: Bool
    var returnEnabled: Bool
    var returnTime: Date
    var returnArriveBy: Bool
    var directOnly: Bool
    var maximumTransfers: Int

    init(
        origin: RailPlace? = nil,
        destination: RailPlace? = nil,
        outboundTime: Date = .now,
        outboundArriveBy: Bool = false,
        returnEnabled: Bool = false,
        returnTime: Date? = nil,
        returnArriveBy: Bool = false,
        directOnly: Bool = false,
        maximumTransfers: Int = 4
    ) {
        self.origin = origin
        self.destination = destination
        self.outboundTime = outboundTime
        self.outboundArriveBy = outboundArriveBy
        self.returnEnabled = returnEnabled
        self.returnTime = returnTime ?? outboundTime
        self.returnArriveBy = returnArriveBy
        self.directOnly = directOnly
        self.maximumTransfers = min(maximumTransfers, 4)
    }

    var canSearch: Bool {
        guard let origin, let destination else { return false }
        return origin.id != destination.id
    }

    var outboundTimeZoneIdentifier: String? {
        outboundArriveBy ? destination?.timeZoneIdentifier : origin?.timeZoneIdentifier
    }

    var returnTimeZoneIdentifier: String? {
        returnArriveBy ? origin?.timeZoneIdentifier : destination?.timeZoneIdentifier
    }

    mutating func swapPlaces() {
        swap(&origin, &destination)
    }

    func outboundCriteria(cursor: String? = nil) -> JourneySearchCriteria? {
        guard let origin, let destination, let outboundTimeZoneIdentifier else { return nil }
        return JourneySearchCriteria(
            originID: origin.id,
            destinationID: destination.id,
            requestedTime: outboundTime,
            timeZoneIdentifier: outboundTimeZoneIdentifier,
            arriveBy: outboundArriveBy,
            maximumTransfers: maximumTransfers,
            cursor: cursor
        )
    }

    func returnCriteria(cursor: String? = nil) -> JourneySearchCriteria? {
        guard returnEnabled,
              let origin,
              let destination,
              let returnTimeZoneIdentifier else { return nil }
        return JourneySearchCriteria(
            originID: destination.id,
            destinationID: origin.id,
            requestedTime: returnTime,
            timeZoneIdentifier: returnTimeZoneIdentifier,
            arriveBy: returnArriveBy,
            maximumTransfers: maximumTransfers,
            cursor: cursor
        )
    }
}
