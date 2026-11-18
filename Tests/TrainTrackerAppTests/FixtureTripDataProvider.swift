import Foundation
import TrainTrackerCore
@testable import TrainTracker

/// Explicit test-only alternative to backend snapshots, with no production fallback path.
struct FixtureTripDataProvider: TripDataProviding {
    let adapter: any RailAdapter

    func searchStations(query: String, source: RailSource) async throws -> [Station] {
        try await adapter.searchStations(query: query)
    }

    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection, source: RailSource?) async throws -> [StopTimeSummary] {
        try await adapter.board(stationID: stationID, at: date, direction: direction)
    }

    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip {
        try await adapter.trip(id: id, serviceDate: serviceDate)
    }

    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip {
        try await adapter.trip(id: trip.id, serviceDate: trip.serviceDate)
    }
}
