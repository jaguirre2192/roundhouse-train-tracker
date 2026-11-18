import Foundation

/// Versioned ActivityKit content shared with the server. All timestamps are Unix seconds.
/// A phase describes a timetable window, never verified passenger or vehicle movement.
public struct TrainLiveActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case upcoming, departureSoon, underway, ended, cancelled, unavailable
    }

    public enum TimingBasis: String, Codable, Hashable, Sendable {
        case scheduled, estimated, unavailable
    }

    public enum PlatformBasis: String, Codable, Hashable, Sendable {
        case scheduled, reported, predicted, unavailable
    }

    public let schemaVersion: Int
    public let phase: Phase
    public let focusName: String
    public let eventTime: Double?
    public let timeZoneIdentifier: String?
    public let timingBasis: TimingBasis
    public let platform: String?
    public let platformBasis: PlatformBasis
    public let platformChanged: Bool
    public let delayMinutes: Int?
    /// The most recent successful fetch, retained when a later refresh fails.
    public let checkedAt: Double?
    /// At or after this instant, the content must be presented as stale.
    public let validUntil: Double
    /// Distinguishes a cancelled selected call from cancellation of every selected call.
    public let isStopCancelled: Bool
    /// Optional in schema 1: "track" at Amtrak stations. Absent in older content, which reads
    /// as "platform", so either side can be updated first.
    public let platformKind: PlatformKind?
    /// Optional in schema 1: the live feed credited for a shown assignment, e.g. "Amtraker".
    public let platformSource: String?
    /// Present only when a reported assignment and a departure belong to the selected boarding call.
    public let boardingPlatformSequence: Int?

    public init(
        schemaVersion: Int = 1,
        phase: Phase,
        focusName: String,
        eventTime: Double? = nil,
        timeZoneIdentifier: String? = nil,
        timingBasis: TimingBasis = .unavailable,
        platform: String? = nil,
        platformBasis: PlatformBasis = .unavailable,
        platformChanged: Bool = false,
        delayMinutes: Int? = nil,
        checkedAt: Double? = nil,
        validUntil: Double,
        isStopCancelled: Bool = false,
        platformKind: PlatformKind? = nil,
        platformSource: String? = nil,
        boardingPlatformSequence: Int? = nil
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.phase = phase
        self.focusName = Self.compactText(focusName, maximumBytes: 160) ?? "Journey"
        self.eventTime = Self.safeTimestamp(eventTime)
        let zone = Self.compactText(timeZoneIdentifier, maximumBytes: 64)
        self.timeZoneIdentifier = zone.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
        self.timingBasis = self.eventTime == nil ? .unavailable : timingBasis
        self.platform = Self.compactText(platform, maximumBytes: 32)
        self.platformBasis = self.platform == nil ? .unavailable : platformBasis
        self.platformChanged = self.platform != nil && platformBasis == .reported && platformChanged
        self.delayMinutes = self.timingBasis == .estimated ? delayMinutes : nil
        self.checkedAt = Self.safeTimestamp(checkedAt)
        self.validUntil = Self.safeTimestamp(validUntil) ?? 0
        self.isStopCancelled = phase == .cancelled && isStopCancelled
        self.platformKind = platformKind
        self.platformSource = self.platform == nil ? nil : Self.compactText(platformSource, maximumBytes: 32)
        self.boardingPlatformSequence = (phase == .upcoming || phase == .departureSoon) && self.platformBasis == .reported
            && self.eventTime != nil ? boardingPlatformSequence.flatMap { $0 >= 0 ? $0 : nil } : nil
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decode(Int.self, forKey: .schemaVersion),
            phase: try values.decode(Phase.self, forKey: .phase),
            focusName: try values.decode(String.self, forKey: .focusName),
            eventTime: try values.decodeIfPresent(Double.self, forKey: .eventTime),
            timeZoneIdentifier: try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier),
            timingBasis: try values.decode(TimingBasis.self, forKey: .timingBasis),
            platform: try values.decodeIfPresent(String.self, forKey: .platform),
            platformBasis: try values.decode(PlatformBasis.self, forKey: .platformBasis),
            platformChanged: try values.decode(Bool.self, forKey: .platformChanged),
            delayMinutes: try values.decodeIfPresent(Int.self, forKey: .delayMinutes),
            checkedAt: try values.decodeIfPresent(Double.self, forKey: .checkedAt),
            validUntil: try values.decode(Double.self, forKey: .validUntil),
            isStopCancelled: try values.decode(Bool.self, forKey: .isStopCancelled),
            platformKind: (try? values.decodeIfPresent(PlatformKind.self, forKey: .platformKind)) ?? nil,
            platformSource: try values.decodeIfPresent(String.self, forKey: .platformSource),
            boardingPlatformSequence: try values.decodeIfPresent(Int.self, forKey: .boardingPlatformSequence)
        )
    }

    /// Restrict timestamps to finite civil dates so arithmetic and JSON encoding stay safe.
    static func safeTimestamp(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-62_135_596_800...253_402_300_799).contains(value) else {
            return nil
        }
        return value
    }

    /// A small content budget leaves room for the activity's immutable attributes below 4 KB.
    private static func compactText(_ text: String?, maximumBytes: Int) -> String? {
        guard let text else { return nil }
        var result = ""
        var byteCount = 0
        for scalar in text.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            let part = String(scalar)
            guard byteCount + part.utf8.count <= maximumBytes else { break }
            result += part
            byteCount += part.utf8.count
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
