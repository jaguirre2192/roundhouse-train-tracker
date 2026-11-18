import ActivityKit
import Foundation
import TrainTrackerCore

struct TrainJourneyAttributes: ActivityAttributes {
    typealias ContentState = TrainLiveActivityState

    let schemaVersion: Int
    let activityKey: String
    let tripID: String
    let boardingStationID: String
    let alightingStationID: String
    let serviceName: String
    let originName: String
    let destinationName: String
    let startedAt: Double
    let boardingStopSequence: Int
    let alightingStopSequence: Int
    /// Short station codes for the Lock Screen ticket ("NYP"), nil when the station has no real
    /// letter code. Optional so activities started by older builds still decode.
    let originCode: String?
    let destinationCode: String?
    /// Absent on existing activities. Watching a service never implies boarding it.
    let isRiding: Bool?

    init(
        schemaVersion: Int = 1, activityKey: String, tripID: String,
        boardingStationID: String, alightingStationID: String,
        serviceName: String, originName: String, destinationName: String,
        startedAt: Double, boardingStopSequence: Int = 0, alightingStopSequence: Int = 1,
        originCode: String? = nil, destinationCode: String? = nil, isRiding: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activityKey = activityKey
        self.tripID = tripID
        self.boardingStationID = boardingStationID
        self.alightingStationID = alightingStationID
        self.serviceName = String(serviceName.prefix(60))
        self.originName = String(originName.prefix(80))
        self.destinationName = String(destinationName.prefix(80))
        self.startedAt = startedAt
        self.boardingStopSequence = boardingStopSequence
        self.alightingStopSequence = alightingStopSequence
        self.originCode = originCode.map { String($0.prefix(5)) }
        self.destinationCode = destinationCode.map { String($0.prefix(5)) }
        self.isRiding = isRiding
    }

    var deepLinkURL: URL? {
        var url = URLComponents()
        url.scheme = "traintracker"
        url.host = "journey"
        url.queryItems = [
            URLQueryItem(name: "trip", value: tripID),
            URLQueryItem(name: "boarding", value: boardingStationID),
            URLQueryItem(name: "alighting", value: alightingStationID),
        ]
        return url.url
    }
}
