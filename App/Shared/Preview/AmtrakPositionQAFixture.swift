#if DEBUG
import Foundation
import TrainTrackerCore

/// Deterministic map fixture for an Amtrak train saved with a Transitous identity. Its refreshed
/// snapshot carries a sample GPS position unless `-AmtrakPositionQABefore` is present.
/// Live server GPS enrichment is verified separately by backend and import integration tests.
enum AmtrakPositionQA {
    static func isEnabled(arguments: [String]) -> Bool { arguments.contains("-AmtrakPositionQA") }
    static func includesPosition(arguments: [String]) -> Bool { !arguments.contains("-AmtrakPositionQABefore") }

    static func trip(on day: Date = .now) -> TrainTrip {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
            let start = calendar.startOfDay(for: day)
            return calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: start)!
        }
        func stop(_ id: String, _ name: String, _ lat: Double, _ lon: Double, sequence: Int, arrival: Date?, departure: Date?) -> StopTime {
            StopTime(
                station: Station(id: RailIdentifier(rawValue: "us:transitous:us-Amtrak_\(id)"), names: [LocalizedStationName(name)],
                                 location: GeoCoordinate(latitude: lat, longitude: lon), countryCode: "US"),
                sequence: sequence, scheduledArrival: arrival, scheduledDeparture: departure
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:transitous:20_us-Amtrak_285229"), source: "transitous", serviceDate: at(0, 0),
            operatorName: "Amtrak", product: "2120", headsign: "Ny Moynihan Train Hall At Penn Station",
            stopTimes: [
                stop("WAS", "Washington Union Station", 38.8973, -77.0063, sequence: 1, arrival: nil, departure: at(17, 5)),
                stop("BAL", "Baltimore Penn Station", 39.3073, -76.6156, sequence: 2, arrival: at(17, 34), departure: at(17, 36)),
                stop("NYP", "Ny Moynihan Train Hall At Penn Station", 40.7506, -73.9935, sequence: 3, arrival: at(20, 5), departure: nil),
            ],
            capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }
}

/// The same snapshot interface as production, supplied entirely by DEBUG-only fixture data.
struct AmtrakPositionQASnapshots: TripDataProviding {
    let template: TrainTrip
    let includesPosition: Bool

    func searchStations(query: String, source: RailSource) async throws -> [Station] { [] }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection, source: RailSource?) async throws -> [StopTimeSummary] { [] }
    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { snapshot }
    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip { snapshot }

    private var snapshot: TrainTrip {
        guard includesPosition else { return template }
        return TrainTrip(
            id: template.id, source: template.source, serviceDate: template.serviceDate,
            operatorName: template.operatorName, product: template.product, headsign: template.headsign,
            stopTimes: template.stopTimes,
            positions: [VehiclePosition(
                coordinate: GeoCoordinate(latitude: 39.176, longitude: -76.694), source: .real,
                confidence: 1, asOf: .now
            )],
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: false,
                                               hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }
}
#endif
