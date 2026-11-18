import MapKit
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class TripRouteMapEvidenceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_789_500_000)
    private let coordinates = [
        GeoCoordinate(latitude: 40, longitude: -75),
        GeoCoordinate(latitude: 40.5, longitude: -75),
        GeoCoordinate(latitude: 41, longitude: -75),
    ]

    func testElapsedTimetableAndLegacyFlagsNeverDrawATraveledLine() {
        for exact in [false, true] {
            let trip = trip(exact: exact)
            let routes = TripRouteMapGeometry.drawnRoutes(in: trip, position: nil, referenceDate: date)
            XCTAssertTrue(routes.passed.isEmpty)
            XCTAssertFalse(routes.upcoming.isEmpty)
            XCTAssertNil(TripRouteMapGeometry.observedNextStop(in: trip, referenceDate: date))
            XCTAssertFalse(TripRouteMapGeometry.mapStops(in: trip, nearbyNextStop: nil, referenceDate: date)
                .contains { $0.role == .passed || $0.role == .next })
        }
    }

    func testExplicitPassageEndsTrailAtThatStopRatherThanTheNextStop() throws {
        for exact in [false, true] {
            let trip = trip(exact: exact, passages: [1: date.addingTimeInterval(-60)])
            let routes = TripRouteMapGeometry.drawnRoutes(in: trip, position: nil, referenceDate: date)
            XCTAssertEqual(try XCTUnwrap(routes.passed.last).latitude, 40.5, accuracy: 0.000_001)
            XCTAssertEqual(try XCTUnwrap(routes.upcoming.first).latitude, 40.5, accuracy: 0.000_001)
            let markers = TripRouteMapGeometry.mapStops(in: trip, nearbyNextStop: nil, referenceDate: date)
            XCTAssertEqual(markers.first { $0.role == .passed }?.stop.id, trip.stopTimes[1].id)
        }
    }

    func testFreshPositionBehindTimetableOverridesLaterPassageFlags() throws {
        let fix = position()
        for exact in [false, true] {
            let trip = trip(exact: exact, positions: [fix], passages: [1: date.addingTimeInterval(-60)])
            let routes = TripRouteMapGeometry.drawnRoutes(in: trip, position: fix, referenceDate: date)
            XCTAssertEqual(try XCTUnwrap(routes.passed.last).latitude, 40.25, accuracy: 0.000_001)
            XCTAssertEqual(TripRouteMapGeometry.observedNextStop(in: trip, referenceDate: date)?.id,
                           trip.stopTimes[1].id)
            XCTAssertFalse(TripRouteMapGeometry.mapStops(in: trip, nearbyNextStop: nil, referenceDate: date)
                .contains { $0.role == .passed && $0.stop.id == trip.stopTimes[1].id })
        }
    }

    func testUnusablePositionsCannotAdvanceRouteOrGlide() throws {
        let fixes = [
            position(asOf: date.addingTimeInterval(-301)),
            position(asOf: date.addingTimeInterval(1)),
            position(longitude: -74.9),
            position(source: .inferred),
        ]
        for exact in [false, true] {
            for fix in fixes {
                let trip = trip(exact: exact, positions: [fix])
                XCTAssertTrue(TripRouteMapGeometry.passedRoute(in: trip, position: fix, referenceDate: date).isEmpty)
                XCTAssertNil(TripRouteMapGeometry.observedNextStop(in: trip, referenceDate: date))
                let path = try XCTUnwrap(RoutePath(coordinates: TripRouteMapGeometry.routeCoordinates(in: trip)))
                XCTAssertNil(TrainGlide(trip: trip, position: fix, path: path, referenceDate: date))
            }
        }
    }

    func testExternalPositionArgumentIsNotEvidenceForThisTrip() throws {
        for exact in [false, true] {
            let trip = trip(exact: exact)
            let external = position()
            XCTAssertTrue(TripRouteMapGeometry.passedRoute(in: trip, position: external, referenceDate: date).isEmpty)
            let path = try XCTUnwrap(RoutePath(coordinates: TripRouteMapGeometry.routeCoordinates(in: trip)))
            XCTAssertNil(TrainGlide(trip: trip, position: external, path: path, referenceDate: date))
        }
    }

    func testFutureStopReportDoesNotAdvanceRouteOrMarkers() {
        let trip = trip(passages: [1: date.addingTimeInterval(1)])
        XCTAssertTrue(TripRouteMapGeometry.passedRoute(in: trip, position: nil, referenceDate: date).isEmpty)
        XCTAssertNil(TripRouteMapGeometry.observedNextStop(in: trip, referenceDate: date))
        XCTAssertFalse(TripRouteMapGeometry.mapStops(in: trip, nearbyNextStop: nil, referenceDate: date)
            .contains { $0.role == .passed || $0.role == .next })
    }

    func testAmbiguousLoopPositionCannotAdvanceRouteOrGlide() throws {
        let fix = position()
        // The same fix projects to two separated parts of the route; direction is unknown.
        let loop = [coordinates[0], coordinates[1], coordinates[0], coordinates[2]]
        let trip = trip(positions: [fix], shape: loop)
        XCTAssertNil(TripRouteMapGeometry.confirmedPosition(in: trip, referenceDate: date))
        XCTAssertTrue(TripRouteMapGeometry.passedRoute(in: trip, position: fix, referenceDate: date).isEmpty)
        let path = try XCTUnwrap(RoutePath(coordinates: TripRouteMapGeometry.routeCoordinates(in: trip)))
        XCTAssertNil(TrainGlide(trip: trip, position: fix, path: path, referenceDate: date))
    }

    func testMarkerExtrapolationDoesNotExtendConfirmedTrail() throws {
        let fix = position()
        let trip = trip(positions: [fix], timetableOffset: -600)
        let path = try XCTUnwrap(RoutePath(coordinates: TripRouteMapGeometry.routeCoordinates(in: trip)))
        let glide = try XCTUnwrap(TrainGlide(trip: trip, position: fix, path: path, referenceDate: date))
        XCTAssertFalse(glide.isEstimated(at: date))
        XCTAssertTrue(glide.isEstimated(at: date.addingTimeInterval(1)), "Even small forward movement is estimated")
        XCTAssertGreaterThan(glide.coordinate(at: date.addingTimeInterval(60)).latitude, fix.coordinate.latitude)
        for time in [date, date.addingTimeInterval(60)] {
            let routes = TripRouteMapGeometry.drawnRoutes(in: trip, position: fix, referenceDate: time)
            XCTAssertEqual(try XCTUnwrap(routes.passed.last).latitude, fix.coordinate.latitude, accuracy: 0.000_001)
        }
    }

    func testStationaryGlideKeepsTheReportedCoordinate() throws {
        let fix = position(longitude: -75.001)
        let trip = trip(positions: [fix], timetableOffset: -600)
        let path = try XCTUnwrap(RoutePath(coordinates: TripRouteMapGeometry.routeCoordinates(in: trip)))
        let glide = try XCTUnwrap(TrainGlide(trip: trip, position: fix, path: path, referenceDate: date))
        XCTAssertEqual(glide.coordinate(at: date).longitude, fix.coordinate.longitude, accuracy: 0.000_001)
        XCTAssertFalse(glide.isEstimated(at: date))
    }

    private func position(
        longitude: Double = -75, source: PositionSource = .real, asOf: Date? = nil
    ) -> VehiclePosition {
        VehiclePosition(coordinate: GeoCoordinate(latitude: 40.25, longitude: longitude),
                        source: source, confidence: 1, asOf: asOf ?? date)
    }

    private func trip(
        exact: Bool = true, positions: [VehiclePosition] = [], passages: [Int: Date] = [:],
        timetableOffset: TimeInterval = -3_600, shape: [GeoCoordinate]? = nil
    ) -> TrainTrip {
        let stops = coordinates.enumerated().map { index, coordinate in
            StopTime(
                station: Station(id: RailIdentifier(region: "eu", source: "transitous", nativeID: "stop-\(index)"),
                                 names: [LocalizedStationName("Stop \(index)")], location: coordinate, countryCode: "ES"),
                sequence: index,
                scheduledArrival: index > 0 ? date.addingTimeInterval(timetableOffset + Double(index) * 1_800) : nil,
                scheduledDeparture: index < 2 ? date.addingTimeInterval(timetableOffset + Double(index) * 1_800 + 60) : nil,
                isPassed: true,
                passageObservedAt: passages[index]
            )
        }
        let shape = shape ?? coordinates
        return TrainTrip(
            id: RailIdentifier(region: "eu", source: "transitous", nativeID: "map-evidence"),
            source: "transitous", serviceDate: date, operatorName: "Renfe", product: "AVE", headsign: "Stop 2",
            stopTimes: stops,
            routeGeometry: exact ? RouteGeometry(source: "test", segments: [
                .init(encodedPolyline: polyline(shape), precision: 5, pointCount: shape.count)
            ]) : nil,
            positions: positions,
            capabilities: RealtimeCapabilities(hasPositions: true, hasPlatforms: false,
                                               hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }

    private func polyline(_ coordinates: [GeoCoordinate]) -> String {
        var previous = [0, 0]
        var bytes: [UInt8] = []
        for coordinate in coordinates {
            for (axis, value) in [coordinate.latitude, coordinate.longitude].enumerated() {
                let integer = Int((value * 100_000).rounded())
                let delta = integer - previous[axis]
                previous[axis] = integer
                var encoded = delta < 0 ? ~(delta << 1) : delta << 1
                while encoded >= 0x20 {
                    bytes.append(UInt8((encoded & 0x1f) | 0x20) + 63)
                    encoded >>= 5
                }
                bytes.append(UInt8(encoded) + 63)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
