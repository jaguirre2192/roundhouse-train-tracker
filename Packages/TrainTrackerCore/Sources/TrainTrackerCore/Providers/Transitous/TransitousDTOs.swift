import Foundation

struct TransitousGeocodeDTO: Decodable, Sendable {
    let type: String
    let name: String
    let id: String
    let lat: Double
    let lon: Double
    let country: String?
    let tz: String?
    let modes: [String]?
}

struct TransitousAlertDTO: Decodable, Sendable {
    let code: String?
    let cause: String?
    let headerText: String
    let descriptionText: String
    let severityLevel: String?
}

struct TransitousPlaceDTO: Decodable, Sendable {
    let name: String
    let stopId: String?
    let lat: Double
    let lon: Double
    let tz: String?
    let arrival: String?
    let departure: String?
    let scheduledArrival: String?
    let scheduledDeparture: String?
    let scheduledTrack: String?
    let track: String?
    let cancelled: Bool?
    let alerts: [TransitousAlertDTO]?
}

struct TransitousStopTimeDTO: Decodable, Sendable {
    let place: TransitousPlaceDTO
    let mode: String
    let realTime: Bool?
    let headsign: String?
    let tripFrom: TransitousPlaceDTO?
    let tripTo: TransitousPlaceDTO?
    let agencyName: String?
    let tripId: String
    let routeShortName: String?
    let routeLongName: String?
    let tripShortName: String?
    let displayName: String?
    let cancelled: Bool?
    let tripCancelled: Bool?
}

struct TransitousStopTimesDTO: Decodable, Sendable {
    let stopTimes: [TransitousStopTimeDTO]
    let place: TransitousPlaceDTO
}

struct TransitousRouteGeometryDTO: Decodable, Sendable {
    let points: String
    let precision: Int
    let length: Int
}

struct TransitousLegDTO: Decodable, Sendable {
    let mode: String
    let from: TransitousPlaceDTO
    let to: TransitousPlaceDTO
    let duration: Int?
    let startTime: String?
    let endTime: String?
    let scheduledStartTime: String?
    let scheduledEndTime: String?
    let realTime: Bool?
    let headsign: String?
    let agencyName: String?
    let tripId: String?
    let routeShortName: String?
    let tripShortName: String?
    let displayName: String?
    let cancelled: Bool?
    let intermediateStops: [TransitousPlaceDTO]?
    let legGeometry: TransitousRouteGeometryDTO?
}

struct TransitousItineraryDTO: Decodable, Sendable {
    let id: String?
    let startTime: String
    let endTime: String
    let duration: Int
    let transfers: Int
    let legs: [TransitousLegDTO]
}

struct TransitousPlanDTO: Decodable, Sendable {
    let itineraries: [TransitousItineraryDTO]
}

struct TransitousHealthDTO: Decodable, Sendable {
    let rt: Bool
    let gbfs: Bool
}

typealias TransitousGeocodeResponse = [TransitousGeocodeDTO]
