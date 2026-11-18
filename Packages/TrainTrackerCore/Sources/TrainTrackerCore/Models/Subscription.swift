import Foundation

public struct PushPreferences: Codable, Hashable, Sendable {
    public let delayThresholdMinutes: Int
    public let notifiesPlatformChanges: Bool
    public let notifiesCancellations: Bool
    public let notifiesDisruptions: Bool

    public init(
        delayThresholdMinutes: Int = 5,
        notifiesPlatformChanges: Bool = true,
        notifiesCancellations: Bool = true,
        notifiesDisruptions: Bool = true
    ) {
        self.delayThresholdMinutes = max(delayThresholdMinutes, 0)
        self.notifiesPlatformChanges = notifiesPlatformChanges
        self.notifiesCancellations = notifiesCancellations
        self.notifiesDisruptions = notifiesDisruptions
    }
}

public struct DeliveredEvent: Codable, Hashable, Sendable {
    public let eventID: String
    public let deliveredAt: Date

    public init(eventID: String, deliveredAt: Date) {
        self.eventID = eventID
        self.deliveredAt = deliveredAt
    }
}

public struct TripSubscription: Identifiable, Codable, Hashable, Sendable {
    public let id: RailIdentifier
    public let deviceID: String
    public let tripID: RailIdentifier
    public let boardingStationID: RailIdentifier
    public let alightingStationID: RailIdentifier
    public let watchFrom: Date
    public let pushPreferences: PushPreferences
    public let deliveredEvents: [DeliveredEvent]

    public init(
        id: RailIdentifier,
        deviceID: String,
        tripID: RailIdentifier,
        boardingStationID: RailIdentifier,
        alightingStationID: RailIdentifier,
        watchFrom: Date,
        pushPreferences: PushPreferences = PushPreferences(),
        deliveredEvents: [DeliveredEvent] = []
    ) {
        self.id = id
        self.deviceID = deviceID
        self.tripID = tripID
        self.boardingStationID = boardingStationID
        self.alightingStationID = alightingStationID
        self.watchFrom = watchFrom
        self.pushPreferences = pushPreferences
        self.deliveredEvents = deliveredEvents
    }
}
