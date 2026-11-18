public struct RailPlace: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case city
        case station
    }

    public let id: RailIdentifier
    public let kind: Kind
    public let displayName: String
    public let context: String
    public let countryCode: String
    public let timeZoneIdentifier: String
    public let location: GeoCoordinate
    public let eligibleModes: [String]
    public let attributions: [String]

    public init(
        id: RailIdentifier,
        kind: Kind,
        displayName: String,
        context: String,
        countryCode: String,
        timeZoneIdentifier: String,
        location: GeoCoordinate,
        eligibleModes: [String],
        attributions: [String]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.context = context
        self.countryCode = countryCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.eligibleModes = eligibleModes
        self.attributions = attributions
    }
}
