import MapKit
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class TripRouteMapGeometryTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_789_500_000)

    func testExactProviderShapeReplacesStraightStopChordAndSplitsAtPosition() throws {
        let geometry = RouteGeometry(
            source: "Transitous/MOTIS",
            segments: [RouteGeometry.Segment(
                encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
                precision: 5,
                pointCount: 3
            )]
        )
        let coordinates = geometry.coordinates
        let middle = try XCTUnwrap(coordinates.dropFirst().first)
        let position = VehiclePosition(
            coordinate: middle,
            source: .real,
            confidence: 1,
            asOf: referenceDate
        )

        let trip = makeTrip(geometry: geometry, coordinates: coordinates, positions: [position])
        let route = TripRouteMapGeometry.routeCoordinates(in: trip)
        let passed = TripRouteMapGeometry.passedRoute(in: trip, position: position, referenceDate: referenceDate)
        let upcoming = TripRouteMapGeometry.upcomingRoute(in: trip, position: position, referenceDate: referenceDate)

        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[1].latitude, 40.7, accuracy: 0.000_001)
        XCTAssertEqual(route[1].longitude, -120.95, accuracy: 0.000_001)
        XCTAssertEqual(passed.count, 2)
        XCTAssertEqual(upcoming.count, 2)
        XCTAssertEqual(try XCTUnwrap(passed.last).latitude, middle.latitude, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(upcoming.first).longitude, middle.longitude, accuracy: 0.000_001)
    }

    func testTripsWithoutGeometryKeepStationFallback() throws {
        let coordinates = [
            GeoCoordinate(latitude: 39, longitude: -1),
            GeoCoordinate(latitude: 40, longitude: -3),
        ]
        let trip = makeTrip(geometry: nil, coordinates: coordinates)

        let route = TripRouteMapGeometry.routeCoordinates(in: trip)

        XCTAssertEqual(route.count, 2)
        XCTAssertEqual(try XCTUnwrap(route.first).latitude, 39, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(route.last).longitude, -3, accuracy: 0.000_001)
    }

    private func makeTrip(geometry: RouteGeometry?, coordinates: [GeoCoordinate], positions: [VehiclePosition] = []) -> TrainTrip {
        let origin = Station(
            id: RailIdentifier(region: "eu", source: "transitous", nativeID: "origin"),
            names: [LocalizedStationName("Origin")],
            location: coordinates.first ?? GeoCoordinate(latitude: 0, longitude: 0),
            countryCode: "ES"
        )
        let destination = Station(
            id: RailIdentifier(region: "eu", source: "transitous", nativeID: "destination"),
            names: [LocalizedStationName("Destination")],
            location: coordinates.last ?? GeoCoordinate(latitude: 1, longitude: 1),
            countryCode: "ES"
        )
        return TrainTrip(
            id: RailIdentifier(region: "eu", source: "transitous", nativeID: "trip"),
            source: "transitous",
            serviceDate: referenceDate,
            operatorName: "Renfe",
            product: "AVE 05951",
            headsign: "Madrid",
            stopTimes: [
                StopTime(station: origin, sequence: 1, scheduledDeparture: referenceDate.addingTimeInterval(-600), isPassed: true),
                StopTime(station: destination, sequence: 2),
            ],
            routeGeometry: geometry,
            positions: positions,
            capabilities: RealtimeCapabilities(
                hasPositions: true,
                hasPlatforms: true,
                hasRealtimeDelays: true,
                hasAlerts: true,
                granularity: .perStop
            )
        )
    }
}
