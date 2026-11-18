import Foundation
import TrainTrackerCore

enum TrainPositionStatus: Equatable {
    case live
    case recent
    case stale
    case estimated
    case unavailable

    static let liveInterval: TimeInterval = 5 * 60
    static let recentInterval: TimeInterval = 15 * 60

    init(position: VehiclePosition?, now: Date = .now) {
        guard let position else {
            self = .unavailable
            return
        }
        guard position.source == .real else {
            self = .estimated
            return
        }
        let age = now.timeIntervalSince(position.asOf)
        guard age >= -120 else {
            self = .stale
            return
        }
        if age <= Self.liveInterval {
            self = .live
        } else if age <= Self.recentInterval {
            self = .recent
        } else {
            self = .stale
        }
    }

    var title: String {
        switch self {
        case .live: "Live position"
        case .recent: "Recently updated"
        case .stale: "Position stale"
        case .estimated: "Estimated position"
        case .unavailable: "Position unavailable"
        }
    }

    var annotationLabel: String {
        switch self {
        case .live: "Live train position"
        case .recent: "Recently updated train position"
        case .stale: "Stale train position"
        case .estimated: "Estimated train position"
        case .unavailable: "Train position unavailable"
        }
    }

    var markerLabel: String {
        switch self {
        case .live: "LIVE"
        case .recent: "RECENT"
        case .stale: "STALE"
        case .estimated: "EST"
        case .unavailable: "N/A"
        }
    }
}
