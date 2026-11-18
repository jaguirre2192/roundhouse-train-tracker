import Foundation

public struct JourneyLeg: Identifiable, Codable, Hashable, Sendable {
    public let id: RailIdentifier
    public let tripID: RailIdentifier
    public let boardingStationID: RailIdentifier
    public let alightingStationID: RailIdentifier

    public init(
        id: RailIdentifier,
        tripID: RailIdentifier,
        boardingStationID: RailIdentifier,
        alightingStationID: RailIdentifier
    ) {
        self.id = id
        self.tripID = tripID
        self.boardingStationID = boardingStationID
        self.alightingStationID = alightingStationID
    }
}

public struct JourneyTransfer: Codable, Hashable, Sendable {
    public let stationID: RailIdentifier
    public let minimumConnectionMinutes: Int
    public let walkMinutes: Int?
    public let platformChange: Bool?

    public init(
        stationID: RailIdentifier,
        minimumConnectionMinutes: Int,
        walkMinutes: Int? = nil,
        platformChange: Bool? = nil
    ) {
        self.stationID = stationID
        self.minimumConnectionMinutes = minimumConnectionMinutes
        self.walkMinutes = walkMinutes
        self.platformChange = platformChange
    }
}

public struct Journey: Identifiable, Codable, Hashable, Sendable {
    public let id: RailIdentifier
    public let legs: [JourneyLeg]
    public let transfers: [JourneyTransfer]

    public init(
        id: RailIdentifier,
        legs: [JourneyLeg],
        transfers: [JourneyTransfer] = []
    ) {
        self.id = id
        self.legs = legs
        self.transfers = transfers
    }
}
