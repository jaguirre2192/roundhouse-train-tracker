import TrainTrackerCore
import UIKit
import XCTest
@testable import TrainTracker

@MainActor
final class AnnualRailPrintTests: XCTestCase {
    private let newYear = Date(timeIntervalSince1970: 1_798_764_600) // 2027-01-01 00:50 UTC

    private func stub(_ id: String, at date: Date? = nil, zone: String? = nil,
                      meters: Double = 100_000, origin: String? = nil, destination: String? = nil,
                      coordinates: [(Double, Double)] = [(40, -75), (41, -74)]) -> TravelLogEntry {
        let day = date ?? newYear
        return TravelLogEntry(id: id, product: id, operatorName: "Rail", originName: origin ?? "From \(id)", originCode: nil,
            destinationName: destination ?? "To \(id)", destinationCode: nil, departure: day, arrival: day.addingTimeInterval(3_600),
            distanceMeters: meters, stopCount: 2, arrivalDelayMinutes: 0,
            path: coordinates.map { .init(latitude: $0.0, longitude: $0.1) }, originTimeZoneIdentifier: zone)
    }

    func testBoardingYearSurvivesTravelAndLegacyStubsUseUTC() throws {
        let west = stub("Acela", zone: "America/New_York")
        let east = stub("Renfe", zone: "Europe/Madrid")
        let legacy = stub("older")
        XCTAssertEqual(west.logYear, 2026)
        XCTAssertEqual(east.logYear, 2027)
        XCTAssertEqual(legacy.logYear, 2027)
        let roundTrip = try JSONDecoder().decode(TravelLogEntry.self, from: JSONEncoder().encode(west))
        XCTAssertEqual(roundTrip.logYear, 2026)
        let older = try JSONDecoder().decode(TravelLogEntry.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(older.originTimeZoneIdentifier)
        XCTAssertEqual(try XCTUnwrap(AnnualRailPrint(year: 2026, entries: [west, east, legacy])).entries.map(\.id), ["Acela"])
        XCTAssertNil(AnnualRailPrint(year: 2025, entries: [west, east]))
    }

    func testOnlyMeasuredRidesContributeDistancesAndTheLongestLabel() throws {
        let short = stub("short", meters: 30_000)
        let long = stub("long", meters: 120_000)
        let incomplete = stub("unknown", meters: 900_000, coordinates: [(0, 0), (25, 73)])
        let edition = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: [short, incomplete, long]))
        XCTAssertEqual(edition.entries.count, 3)
        XCTAssertEqual(edition.longest?.rides.map(\.id), ["long"])
        XCTAssertEqual(edition.longestLabel, "Longest mapped ride")
        XCTAssertEqual(edition.mappedDistance, 150_000)
        let unmapped = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: [incomplete]))
        XCTAssertNil(unmapped.longest)
        XCTAssertNil(unmapped.distanceLabel)
        XCTAssertTrue(unmapped.plates.isEmpty)
    }

    func testNearbyLinesShareAPlateWithoutAnInventedConnectionAndDistantRidesGetTheirOwnInset() throws {
        let eastern = stub("A", meters: 900_000)
        let nearby = stub("B", coordinates: [(40.5, -75.1), (41.2, -75.2)])
        let spain = stub("C", coordinates: [(40.4, -3.7), (39.5, -0.37)])
        let edition = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: [eastern, nearby, spain]))
        XCTAssertEqual(edition.plates.map { $0.routes.count }, [2, 1])
        let lines = edition.plates[0].projected(in: CGRect(x: 5, y: 5, width: 200, height: 200))
        XCTAssertEqual(lines.map(\.count), [2, 2])
        XCTAssertNotEqual(lines[0].last, lines[1].first)
    }

    func testLoopRoutesAndDateLineUseTheirActualGeometry() throws {
        let loop = stub("loop", coordinates: [(45, 178), (46, 179), (45, 178)])
        let crossing = stub("dateline", coordinates: [(45, 179), (45, -179), (46, -178)])
        let edition = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: [loop, crossing]))
        let plate = try XCTUnwrap(edition.plates.first)
        XCTAssertEqual(edition.plates.count, 1)
        let lines = plate.projected(in: CGRect(x: 3, y: 3, width: 200, height: 200))
        let crossed = try XCTUnwrap(zip(plate.routes, lines).first { $0.0.entry.id == "dateline" }?.1)
        XCTAssertLessThan(crossed[0].x, crossed[1].x)
        XCTAssertGreaterThan(crossed[1].y, crossed[2].y)
    }

    func testCompleteBookedJourneyUsesRiderBoundsAndDuplicateImportsDoNotAddDistance() throws {
        let route = connectedRides()
        let booked = booking(route.map(\.leg))
        let stubs = route.map(\.stub)
        let edition = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: stubs + [stubs[0]],
            plans: [booked, booking(route.map(\.leg))]))
        XCTAssertEqual(edition.rideCountLabel, "2 rides")
        XCTAssertEqual(edition.mappedDistance, 310_000)
        XCTAssertEqual(edition.longest?.originName, "Montpellier")
        XCTAssertEqual(edition.longest?.destinationName, "Barcelona")
        XCTAssertEqual(edition.longest?.distanceMeters, 310_000)
        XCTAssertEqual(edition.longestLabel, "Longest journey")
    }

    func testMissingMismatchedOrWatchingLegCannotCompleteTheBooking() throws {
        let route = connectedRides()
        let booked = booking(route.map(\.leg))
        let partial = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: [route[0].stub], plans: [booked]))
        XCTAssertEqual(partial.longestLabel, "Longest ride")
        let watching = Set([try XCTUnwrap(route[1].leg.resolvedTripID)])
        let watched = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: route.map(\.stub), plans: [booked], watching: watching))
        XCTAssertEqual(watched.entries.map(\.id), [route[0].stub.id])
        XCTAssertEqual(watched.longest?.distanceMeters, route[0].stub.distanceMeters)
        let fullTrain = stub(route[1].stub.id, at: route[1].stub.departure, origin: "Paris", destination: "Barcelona",
                             coordinates: [(48.85, 2.35), (41.38, 2.17)])
        let differentBounds = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: [route[0].stub, fullTrain], plans: [booked]))
        XCTAssertEqual(differentBounds.longestLabel, "Longest ride")
    }

    func testConflictingCompleteBookingsCannotReuseARecordedLeg() throws {
        let route = connectedRides()
        let replacement = connectedRides(alternative: true)
        let stubs = [route[0].stub, route[1].stub, replacement[1].stub]
        let edition = try XCTUnwrap(AnnualRailPrint(year: 2027, entries: stubs,
            plans: [booking(route.map(\.leg)), booking(replacement.map(\.leg))]))
        XCTAssertEqual(edition.longestLabel, "Longest ride")
        XCTAssertEqual(edition.longest?.distanceMeters, 210_000)
    }

    private func connectedRides(alternative: Bool = false) -> [(stub: TravelLogEntry, leg: JourneyPlanSegment)] {
        func station(_ name: String, lat: Double, lon: Double) -> RailPlace {
            RailPlace(id: RailIdentifier(rawValue: "rail:station:" + name), kind: .station,
                      displayName: name, context: "", countryCode: "", timeZoneIdentifier: "Europe/Paris",
                      location: GeoCoordinate(latitude: lat, longitude: lon), eligibleModes: ["rail"], attributions: [])
        }
        let start = station("Montpellier", lat: 43.6, lon: 3.88)
        let change = station("Figueres", lat: 42.25, lon: 2.94)
        let end = alternative ? station("Girona", lat: 41.98, lon: 2.82) : station("Barcelona", lat: 41.38, lon: 2.17)
        func ride(_ id: String, _ from: RailPlace, _ to: RailPlace, after seconds: Double, meters: Double)
            -> (stub: TravelLogEntry, leg: JourneyPlanSegment) {
            let date = newYear.addingTimeInterval(seconds)
            let stub = self.stub(id, at: date, meters: meters, origin: from.displayName, destination: to.displayName,
                                  coordinates: [(from.location.latitude, from.location.longitude), (to.location.latitude, to.location.longitude)])
            let leg = JourneyPlanSegment(id: id, kind: .rail, from: from, to: to, departure: date, arrival: stub.arrival,
                                         resolvedTripID: RailIdentifier(rawValue: id))
            return (stub, leg)
        }
        return [ride("first", start, change, after: 0, meters: 210_000),
                ride(alternative ? "backup" : "second", change, end, after: 4_200, meters: 100_000)]
    }

    private func booking(_ legs: [JourneyPlanSegment]) -> TrackedJourneyPlan {
        let direction = JourneyPlanDirection(fingerprint: "outbound", departure: newYear, arrival: newYear.addingTimeInterval(9_000),
                                             childTripIDs: legs.compactMap(\.resolvedTripID), selectedSegments: legs)
        return TrackedJourneyPlan(id: UUID(), createdAt: newYear, origin: legs[0].from, destination: legs[legs.count - 1].to,
                                  outbound: direction, returnDirection: nil, preExistingChildTripIDs: [])
    }

    func testExportIsTheFullResolutionPortraitPrint() throws {
        let samples = TravelLogEntry.previewSamples
        let year = try XCTUnwrap(samples.first).logYear
        let edition = try XCTUnwrap(AnnualRailPrint(year: year, entries: samples))
        let item = try XCTUnwrap(TravelLogShareItem(edition: edition))
        let source = item.activityItemSource
        let controller = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        let payload = try XCTUnwrap(source.activityViewController(controller, itemForActivityType: .copyToPasteboard) as? UIImage)
        let png = try XCTUnwrap(payload.pngData())
        let decoded = try XCTUnwrap(UIImage(data: png)?.cgImage)
        XCTAssertEqual(decoded.width, 1080)
        XCTAssertEqual(decoded.height, 1440)
        XCTAssertEqual(png, try XCTUnwrap(item.image.pngData()), "The native Copy activity must receive the complete printed artwork")
        XCTAssertEqual(source.activityViewController?(controller, subjectForActivityType: .copyToPasteboard), "\(String(year)) by rail · Roundhouse")
        let output = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        output.name = "annual-rail-print-export"
        output.lifetime = .keepAlways
        add(output)
    }
}
