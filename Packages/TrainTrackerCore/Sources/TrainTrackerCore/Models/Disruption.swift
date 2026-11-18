import Foundation

public enum AlertSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case minor
    case major
    case critical
}

public struct RailAlert: Identifiable, Codable, Hashable, Sendable {
    public let id: RailIdentifier
    public let severity: AlertSeverity
    public let cause: String?
    public let affectedTripIDs: [RailIdentifier]
    public let affectedStationIDs: [RailIdentifier]
    public let message: String
    public let validFrom: Date?
    public let validUntil: Date?

    public init(
        id: RailIdentifier,
        severity: AlertSeverity,
        cause: String? = nil,
        affectedTripIDs: [RailIdentifier] = [],
        affectedStationIDs: [RailIdentifier] = [],
        message: String,
        validFrom: Date? = nil,
        validUntil: Date? = nil
    ) {
        self.id = id
        self.severity = severity
        self.cause = cause
        self.affectedTripIDs = affectedTripIDs
        self.affectedStationIDs = affectedStationIDs
        self.message = message
        self.validFrom = validFrom
        self.validUntil = validUntil
    }
}

public enum PositionSource: String, Codable, Sendable {
    case real
    case inferred
}

public enum PositionTimestampBasis: String, Codable, Sendable {
    case feedPublicationAndMovement = "feed-publication-and-movement"
}

public struct VehiclePosition: Codable, Hashable, Sendable {
    public let coordinate: GeoCoordinate
    public let heading: Double?
    public let source: PositionSource
    public let confidence: Double
    public let asOf: Date
    /// An explicitly corrected feed clock is an observation of movement by the feed.
    public let timestampBasis: PositionTimestampBasis?

    public init(
        coordinate: GeoCoordinate,
        heading: Double? = nil,
        source: PositionSource,
        confidence: Double,
        asOf: Date,
        timestampBasis: PositionTimestampBasis? = nil
    ) {
        self.coordinate = coordinate
        self.heading = heading
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.asOf = asOf
        self.timestampBasis = timestampBasis
    }
}
