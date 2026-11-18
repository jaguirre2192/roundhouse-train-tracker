import Foundation
import TrainTrackerCore

enum RailSource: String, Hashable, Sendable {
    case unitedStates
    case europe
}

/// Carries the provider selected by unified search without exposing it as a user choice.
struct RailStationMatch: Identifiable, Hashable, Sendable {
    let station: Station
    let source: RailSource

    var id: String { "\(source.rawValue):\(station.id.rawValue)" }
}

enum RailStationSearchError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "We couldn't search stations right now. Check your connection and try again."
    }
}
