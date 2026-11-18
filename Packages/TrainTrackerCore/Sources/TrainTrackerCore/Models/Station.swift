import Foundation

public struct GeoCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct LocalizedStationName: Codable, Hashable, Sendable {
    public let value: String
    public let localeIdentifier: String?

    public init(_ value: String, localeIdentifier: String? = nil) {
        self.value = value
        self.localeIdentifier = localeIdentifier
    }
}

public enum StationCodeKind: String, Codable, CaseIterable, Sendable {
    case crs
    case eva
    case gtfs
    case ibnr
    case uic
    case sourceNative
}

public struct Station: Identifiable, Codable, Hashable, Sendable {
    public let id: RailIdentifier
    public let names: [LocalizedStationName]
    public let codes: [StationCodeKind: String]
    public let location: GeoCoordinate
    public let countryCode: String
    public let operatorHints: [String]
    public let timeZoneIdentifier: String?

    public init(
        id: RailIdentifier,
        names: [LocalizedStationName],
        codes: [StationCodeKind: String] = [:],
        location: GeoCoordinate,
        countryCode: String,
        operatorHints: [String] = [],
        timeZoneIdentifier: String? = nil
    ) {
        self.id = id
        self.names = names
        self.codes = codes
        self.location = location
        self.countryCode = countryCode
        self.operatorHints = operatorHints
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var displayName: String {
        names.first?.value ?? id.nativeID ?? id.rawValue
    }
}
