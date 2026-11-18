import Foundation
import TrainTrackerCore

/// Train data crosses the app's backend boundary as complete snapshots, including GPS and
/// platform enrichment. Tests and previews may inject deterministic implementations.
protocol TripDataProviding: Sendable {
    func searchStations(query: String, source: RailSource) async throws -> [Station]
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection, source: RailSource?) async throws -> [StopTimeSummary]
    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip
    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip
}

extension TripSnapshotBackendClient: TripDataProviding {}
