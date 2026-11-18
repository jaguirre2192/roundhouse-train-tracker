import Foundation

public enum RealtimeGranularity: String, Codable, Sendable {
    case perStop
    case timingPoint
    case tripOnly
}

public struct RealtimeCapabilities: Codable, Hashable, Sendable {
    public let hasPositions: Bool
    public let hasPlatforms: Bool
    public let hasRealtimeDelays: Bool
    public let hasAlerts: Bool
    public let granularity: RealtimeGranularity

    public init(
        hasPositions: Bool,
        hasPlatforms: Bool,
        hasRealtimeDelays: Bool,
        hasAlerts: Bool,
        granularity: RealtimeGranularity
    ) {
        self.hasPositions = hasPositions
        self.hasPlatforms = hasPlatforms
        self.hasRealtimeDelays = hasRealtimeDelays
        self.hasAlerts = hasAlerts
        self.granularity = granularity
    }
}
