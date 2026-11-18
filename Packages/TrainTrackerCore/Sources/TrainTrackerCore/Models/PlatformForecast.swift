import Foundation

public struct PlatformForecast: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case positioning
        case likelyPlatform = "likely-platform"
    }

    public enum Confidence: String, Codable, Hashable, Sendable {
        case low
        case medium
        case high
    }

    public enum Horizon: String, Codable, Hashable, Sendable {
        case twentyFourHoursPlus = "24h-plus"
        case sixToTwentyFourHours = "6h-to-24h"
        case oneHourToSixHours = "1h-to-6h"
        case fifteenMinutesToOneHour = "15m-to-1h"
        case underFifteenMinutes = "under-15m"
    }

    public struct Zone: Codable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let platforms: [String]
        public let probability: Double

        public init(id: String, label: String, platforms: [String], probability: Double) {
            self.id = id
            self.label = label
            self.platforms = platforms
            self.probability = probability
        }
    }

    public struct Candidate: Codable, Hashable, Sendable {
        public let platform: String
        public let probability: Double
        public let observationCount: Int

        public init(platform: String, probability: Double, observationCount: Int) {
            self.platform = platform
            self.probability = probability
            self.observationCount = observationCount
        }
    }

    public let state: State
    public let zone: Zone
    public let candidates: [Candidate]
    public let likelyPlatform: String?
    public let confidence: Confidence
    public let evidenceCount: Int
    public let explanation: String
    public let horizon: Horizon
    public let modelVersion: String
    public let timetablePeriod: String
    public let stationMapVersion: String
    public let generatedAt: Date
    public let expiresAt: Date

    public init(
        state: State,
        zone: Zone,
        candidates: [Candidate],
        likelyPlatform: String?,
        confidence: Confidence,
        evidenceCount: Int,
        explanation: String,
        horizon: Horizon,
        modelVersion: String,
        timetablePeriod: String,
        stationMapVersion: String,
        generatedAt: Date,
        expiresAt: Date
    ) {
        self.state = state
        self.zone = zone
        self.candidates = candidates
        self.likelyPlatform = likelyPlatform
        self.confidence = confidence
        self.evidenceCount = evidenceCount
        self.explanation = explanation
        self.horizon = horizon
        self.modelVersion = modelVersion
        self.timetablePeriod = timetablePeriod
        self.stationMapVersion = stationMapVersion
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
    }
}

public enum PlatformKind: String, Codable, Hashable, Sendable {
    case platform
    case track
}

public enum PlatformGuidance: Hashable, Sendable {
    public enum OfficialSource: Hashable, Sendable {
        case scheduled
        case current
    }

    case unavailable
    case positioning(
        zoneLabel: String,
        platforms: [String],
        confidence: PlatformForecast.Confidence,
        explanation: String
    )
    case likelyPlatform(
        platform: String,
        zoneLabel: String,
        confidence: PlatformForecast.Confidence,
        explanation: String
    )
    case official(platform: String, source: OfficialSource, changed: Bool)

    public var summaryText: String {
        summaryText(noun: "Platform", source: nil)
    }

    /// Honest wording for an assignment. A missing value means the live feed has none, not that
    /// the station has not assigned one; a named third-party feed is credited instead of the
    /// operator.
    public func summaryText(noun: String, source: String?) -> String {
        let lower = noun.lowercased()
        switch self {
        case .unavailable:
            return "\(noun) not in live feed · Check station boards"
        case let .positioning(zoneLabel, platforms, _, _):
            return "Wait near \(article(zoneLabel)) · likely \(lower)s \(platforms.joined(separator: "–"))"
        case let .likelyPlatform(platform, _, _, _):
            return "Likely \(lower) \(platform) · prediction"
        case let .official(platform, official, changed):
            let credit = source.map { "via \($0)" }
            if changed { return "\(noun) changed to \(platform) · \(credit ?? "operator confirmed")" }
            return official == .current
                ? "\(noun) \(platform) · \(credit ?? "operator confirmed")"
                : "Scheduled \(lower) \(platform) · \(credit ?? "operator timetable")"
        }
    }

    public var metricValue: String {
        switch self {
        case .unavailable: "Not in feed"
        case let .positioning(zoneLabel, _, _, _): Self.sentenceCase(zoneLabel)
        case let .likelyPlatform(platform, _, _, _): "Likely \(platform)"
        case let .official(platform, _, _): platform
        }
    }

    public var accessibilityText: String {
        isPredicted ? "Roundhouse prediction. \(summaryText)" : summaryText
    }

    public var isPredicted: Bool {
        switch self {
        case .positioning, .likelyPlatform: true
        case .unavailable, .official: false
        }
    }

    public var isOfficialChange: Bool {
        if case let .official(_, _, changed) = self { return changed }
        return false
    }

    private func article(_ value: String) -> String {
        value.lowercased().hasPrefix("the ") ? value : "the \(value)"
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}
