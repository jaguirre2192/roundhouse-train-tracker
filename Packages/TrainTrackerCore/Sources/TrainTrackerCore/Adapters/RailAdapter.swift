import Foundation

public enum BoardDirection: String, Codable, Sendable {
    case arrivals
    case departures
}

public struct StopTimeSummary: Identifiable, Codable, Hashable, Sendable {
    public let tripID: RailIdentifier
    public let serviceDate: Date
    public let stopTime: StopTime
    public let headsign: String
    public let product: String

    public init(
        tripID: RailIdentifier,
        serviceDate: Date,
        stopTime: StopTime,
        headsign: String,
        product: String
    ) {
        self.tripID = tripID
        self.serviceDate = serviceDate
        self.stopTime = stopTime
        self.headsign = headsign
        self.product = product
    }

    public var id: String { "\(tripID.rawValue)#\(stopTime.id)" }
}

public protocol RailAdapter: Sendable {
    var capabilities: RealtimeCapabilities { get }

    func searchStations(query: String) async throws -> [Station]
    func resolveStation(id: RailIdentifier) async throws -> Station
    func board(
        stationID: RailIdentifier,
        at date: Date,
        direction: BoardDirection
    ) async throws -> [StopTimeSummary]
    func trip(id: RailIdentifier, serviceDate: Date) async throws -> TrainTrip
}

public protocol VehiclePositionProviding: RailAdapter {
    func positions(for tripID: RailIdentifier) async throws -> [VehiclePosition]
}

public protocol AlertProviding: RailAdapter {
    func alerts(affecting tripID: RailIdentifier) async throws -> [RailAlert]
}
