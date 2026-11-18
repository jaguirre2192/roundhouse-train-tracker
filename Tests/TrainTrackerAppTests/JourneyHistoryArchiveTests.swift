import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyHistoryArchiveTests: XCTestCase {
    func testMixedTicketsUseBoardingMonthAcrossTimeZonesAndKeepGroupedChildrenOut() throws {
        let februaryInJapan = instant("2026-01-31T16:30:00Z")
        let tokyo = station("TYO", "Tokyo")
        let kyoto = station("KYO", "Kyoto")
        let child = train("nozomi", service: "Nozomi 11", stops: [tokyo, kyoto], at: februaryInJapan)
        let newYork = station("NYP", "New York Penn Station")
        let washington = station("WAS", "Washington Union Station")
        let januaryInNewYork = instant("2026-02-01T03:00:00Z")
        let usa = train("amtrak", service: "Northeast Regional 195", stops: [newYork, washington], at: januaryInNewYork)
        let japan = plan(from: tokyo, to: kyoto, zone: "Asia/Tokyo", at: februaryInJapan, child: child)
        // Another saved booking supplies the standalone train's boarding zone.
        let older = plan(from: newYork, to: washington, zone: "America/New_York", at: instant("2025-12-19T17:00:00Z"))
        let archive = JourneyHistoryArchive(plans: [older, japan], trips: [usa, child], at: instant("2026-03-07T12:00:00Z"))

        XCTAssertEqual(archive.months.map(\.id), [202602, 202601, 202512])
        XCTAssertEqual(archive.months.flatMap(\.tickets).map(\.route), [.journey(japan.id), .train(usa.id), .journey(older.id)])
        let usaTicket = try XCTUnwrap(archive.months[1].tickets.first)
        XCTAssertEqual(usaTicket.zone.identifier, "America/New_York")
        XCTAssertEqual(usaTicket.day.compactMap(\.wholeNumberValue), [3, 1])
        XCTAssertEqual(archive.featuredTicketID(matching: ""), usaTicket.id, "Feature the latest departure instant even across a month boundary in another zone")
        XCTAssertNil(archive.featuredTicketID(matching: "Tokyo"))
    }

    func testSearchUsesBookedEndpointsIntermediateStopsAliasesAndReturnServiceWithoutTrainTermini() throws {
        let start = instant("2026-06-12T09:00:00Z")
        let before = station("ZZB", "Before the booking")
        let boarding = station("CDG", "Aéroport Charles-de-Gaulle TGV")
        let change = station("LIL", "Lille Europe", aliases: ["Lille-Europe"])
        let exit = station("BRU", "Bruxelles-Midi", aliases: ["Brussel-Zuid"])
        let after = station("ZZA", "Beyond the booking")
        let child = train("full", service: "Eurostar 9315", stops: [before, boarding, change, exit, after], at: start)
        let booking = plan(from: boarding, to: exit, zone: "Europe/Paris", at: start.addingTimeInterval(600),
                           child: child, returnService: "TGV 9876")
        let archive = JourneyHistoryArchive(plans: [booking], trips: [child], at: instant("2026-07-10T12:00:00Z"))
        let ticket = try XCTUnwrap(archive.months.first?.tickets.first)

        XCTAssertEqual(ticket.origin, "Aéroport Charles-de-Gaulle TGV")
        XCTAssertEqual(ticket.destination, "Bruxelles-Midi")
        XCTAssertEqual(ticket.service, "Round trip · 2 trains")
        XCTAssertEqual(archive.months.count, 1, "The return in July remains part of its June boarding ticket")
        for query in ["AEROPORT → bruxelles", "from aeroport to bruxelles", "Brussel-Zuid", "CDG LIL BRU", "9315", "9876", "Lille Europe"] {
            XCTAssertEqual(archive.months(matching: query).flatMap(\.tickets).map(\.route), [.journey(booking.id)], query)
        }
        for query in ["Before the booking", "Beyond", "ZZB", "nonexistent"] {
            XCTAssertTrue(archive.months(matching: query).isEmpty, query)
        }
        XCTAssertEqual(archive.months(matching: "   ").flatMap(\.tickets).map(\.id), [ticket.id])
    }

    func testTrainsAndGroupedBookingsInterleaveWithinOneMonthAndFilteringKeepsTheirDestinations() {
        let stations = [station("NYP", "New York Penn Station"), station("ALB", "Albany-Rensselaer")]
        let first = instant("2026-05-01T12:00:00Z")
        let middle = instant("2026-05-08T12:00:00Z")
        let last = instant("2026-05-17T12:00:00Z")
        let old = train("first", service: "Empire Service 231", stops: stations, at: first)
        let plan = plan(from: stations[0], to: stations[1], zone: "America/New_York", at: middle)
        let recent = train("last", service: "Adirondack 69", stops: stations, at: last)
        let archive = JourneyHistoryArchive(plans: [plan], trips: [old, recent], at: instant("2026-06-02T00:00:00Z"))
        let routes: [TripsRoute] = [.train(recent.id), .journey(plan.id), .train(old.id)]

        XCTAssertEqual(archive.months.map(\.id), [202605])
        XCTAssertEqual(archive.months(matching: "Albany").flatMap(\.tickets).map(\.route), routes)
        XCTAssertEqual(archive.months(matching: "231").flatMap(\.tickets).map(\.route), [.train(old.id)])
        XCTAssertNil(archive.featuredTicketID(matching: "231"))
        XCTAssertEqual(archive.featuredTicketID(matching: " "), "individualTrain-\(recent.id.rawValue)")
    }

    func testUnknownStationZoneLabelsUTCAndTiedDeparturesHaveStableOrder() throws {
        let departure = instant("2026-02-09T00:30:00Z")
        let stations = [station("ALP", "Alpha"), station("BET", "Beta")]
        let a = train("a", service: "Express 102", stops: stations, at: departure)
        let b = train("b", service: "Express 103", stops: stations, at: departure)
        let date = instant("2026-02-18T00:00:00Z")
        let archives = [[a, b], [b, a]].map { JourneyHistoryArchive(plans: [], trips: $0, at: date) }
        for archive in archives {
            let tickets = archive.months.flatMap(\.tickets)
            XCTAssertEqual(tickets.map(\.route), [.train(a.id), .train(b.id)])
            XCTAssertEqual(tickets.map { $0.day.compactMap(\.wholeNumberValue) }, [[9], [9]])
            XCTAssertTrue(try XCTUnwrap(tickets.first?.timeText).hasSuffix(" UTC"))
        }
        let untimed = TrainTrip(id: a.id, source: a.source, serviceDate: instant("2026-02-01T00:00:00Z"),
                                operatorName: a.operatorName, product: a.product, headsign: a.headsign,
                                stopTimes: [StopTime(station: stations[0], sequence: 0)], capabilities: a.capabilities)
        let ticket = JourneyHistoryTicket(trip: untimed, plans: [plan(from: stations[0], to: stations[1],
                                                                      zone: "America/New_York", at: departure)])
        XCTAssertNil(ticket.timeText)
        XCTAssertEqual(ticket.departureMonth, 202602)
        XCTAssertEqual(ticket.day.compactMap(\.wholeNumberValue), [1])
    }

    func testWideArchiveSharesThePhysicalCreaseAcrossAsymmetricTicketAndMonthColumns() throws {
        // A 951-point inner window, 760-point archive, and native navigation down the right edge.
        let content: ClosedRange<CGFloat> = 54...814
        let physicalMidX: CGFloat = 475.5
        let flat = try XCTUnwrap(JourneySpreadColumns(content: content, division: physicalMidX...physicalMidX, minimum: 292))
        XCTAssertEqual(content.lowerBound + flat.first + flat.gap / 2, physicalMidX)
        XCTAssertEqual(flat.first + flat.gap + flat.second, 760)
        XCTAssertGreaterThan(flat.first, flat.second)
        let fold = try XCTUnwrap(JourneySpreadColumns(content: content, division: 462...490, minimum: 292))
        XCTAssertLessThan(content.lowerBound + fold.first, 462)
        XCTAssertGreaterThan(content.upperBound - fold.second, 490)
        let ordinary = try XCTUnwrap(JourneySpreadColumns(content: content, division: nil, minimum: 292))
        XCTAssertEqual(ordinary.first, ordinary.second)
        let mirrored = try XCTUnwrap(JourneySpreadColumns(content: content, division: 462...490, minimum: 292, rightToLeft: true))
        XCTAssertEqual(mirrored.first, fold.second)
        XCTAssertNil(JourneySpreadColumns(content: 50...670, division: 473...480, minimum: 292))
    }

    func testHistoryCollectionPairsSmallMonthsAndPrintsTheBookedTransferAndCityScope() throws {
        let preview = try XCTUnwrap(JourneyPlanPreviewData.resolve(arguments: ["-MyTripsTicketHistoryPreview"]))
        let archive = JourneyHistoryArchive(plans: preview.plans, trips: preview.trips, at: try XCTUnwrap(preview.referenceDate))
        let rows = JourneyHistoryArchive.rows(archive.months, pairsSingles: true)
        XCTAssertEqual(rows.map(\.first.id), [202610, 202609])
        XCTAssertEqual(rows.last?.second?.id, 202608)
        XCTAssertEqual(JourneyHistoryArchive.rows(archive.months, pairsSingles: false).count, 3)
        let tickets = try XCTUnwrap(archive.months.first?.tickets)
        let featured = try XCTUnwrap(tickets.first)
        XCTAssertEqual(featured.service, "Via Bruxelles-Midi")
        let trace = try XCTUnwrap(featured.routeTrace)
        XCTAssertEqual(trace.legs.count, 2)
        XCTAssertEqual(trace.legs[0].last, trace.legs[1].first)
        let city = try XCTUnwrap(tickets.last)
        XCTAssertEqual(city.origin, "New York")
        XCTAssertEqual(city.destination, "Washington DC")
        XCTAssertEqual(city.cityScope, "All stations in both cities")
    }

    func testArchiveWaitsForPossibleCompletionAndHasNoClockForFinishedOrUntimedTrains() throws {
        let departure = instant("2026-05-04T12:00:00Z")
        let stations = [station("AAA", "Alpha"), station("BBB", "Beta")]
        let past = train("1", service: "Local 1", stops: stations, at: departure.addingTimeInterval(-86400))
        let next = train("2", service: "Local 2", stops: stations, at: departure)
        let unknown = TrainTrip(id: RailIdentifier(rawValue: "test:history:untimed"), source: "fixture",
                                serviceDate: departure, operatorName: "", product: "Local 3",
                                headsign: stations[1].displayName, stopTimes: [StopTime(station: stations[0], sequence: 0)],
                                capabilities: next.capabilities)
        let trips = [past, next, unknown]
        let before = JourneyHistorySelection(plans: [], trips: trips, at: departure.addingTimeInterval(-600))
        let afterArrival = try XCTUnwrap(before.nextCheck)
        XCTAssertEqual(before.routes, [.train(past.id)])
        XCTAssertEqual(afterArrival, departure.addingTimeInterval(600))
        let finished = JourneyHistorySelection(plans: [], trips: trips, at: afterArrival)
        XCTAssertEqual(finished.routes, [.train(past.id), .train(next.id)])
        XCTAssertNil(finished.nextCheck, "Neither an archived trip nor missing timetable data needs a timer")
    }

    func testEngravingUsesBookedCoordinatesAndRetainsGeographicOrientation() throws {
        let before = station("AAA", "Before", location: .init(latitude: 42, longitude: -2))
        let from = station("PNO", "Paris Nord", location: .init(latitude: 48.88, longitude: 2.35))
        let middle = station("LIL", "Lille Europe", location: .init(latitude: 50.64, longitude: 3.07))
        let to = station("BRU", "Bruxelles-Midi", location: .init(latitude: 50.84, longitude: 4.34))
        let beyond = station("ZZZ", "Beyond", location: .init(latitude: 54, longitude: 6))
        let day = instant("2026-05-04T12:00:00Z")
        let train = train("9301", service: "Eurostar 9301", stops: [before, from, middle, to, beyond], at: day)
        let plan = plan(from: from, to: to, zone: "Europe/Paris", at: day.addingTimeInterval(600), child: train)
        let archive = JourneyHistoryArchive(plans: [plan], trips: [train], at: day.addingTimeInterval(100_000))
        let trace = try XCTUnwrap(archive.months.first?.tickets.first?.routeTrace)
        XCTAssertEqual(trace.legs, [[from.location, middle.location, to.location]])
        XCTAssertEqual(trace.originCode, "PNO")
        XCTAssertEqual(trace.destinationCode, "BRU")
        let points = try XCTUnwrap(trace.projected(in: CGRect(x: 0, y: 0, width: 100, height: 80)).first)
        XCTAssertGreaterThan(points[2].x, points[0].x, "Brussels is east of Paris")
        XCTAssertLessThan(points[2].y, points[0].y, "North points up")

        let entire = try XCTUnwrap(JourneyHistoryTicket(trip: train, plans: []).routeTrace)
        XCTAssertEqual(entire.legs.first?.first, before.location)
        XCTAssertEqual(entire.legs.first?.last, beyond.location)
    }

    func testEngravingOmitsUnknownEndpointsAndKeepsAntimeridianCrossingsShort() throws {
        let west = GeoCoordinate(latitude: 51, longitude: 179)
        let east = GeoCoordinate(latitude: 51, longitude: -179)
        for bad in [GeoCoordinate(latitude: 0, longitude: 0), .init(latitude: .nan, longitude: 2),
                    .init(latitude: 22, longitude: 182)] {
            XCTAssertNil(JourneyHistoryRouteTrace(legs: [[west, bad]], originCode: nil, destinationCode: nil))
            XCTAssertNil(JourneyHistoryRouteTrace(legs: [[bad, east]], originCode: nil, destinationCode: nil))
        }
        XCTAssertNil(JourneyHistoryRouteTrace(legs: [[west, west]], originCode: nil, destinationCode: nil))
        let trace = try XCTUnwrap(JourneyHistoryRouteTrace(legs: [[west, east]], originCode: nil, destinationCode: nil))
        let points = try XCTUnwrap(trace.projected(in: CGRect(x: 0, y: 0, width: 100, height: 80)).first)
        XCTAssertGreaterThan(points[1].x, points[0].x)
        XCTAssertEqual(points[1].y, points[0].y)
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func station(_ code: String, _ name: String, aliases: [String] = [],
                         location: GeoCoordinate = .init(latitude: 0, longitude: 0)) -> Station {
        Station(id: RailIdentifier(rawValue: "test:history:\(code)"),
                names: ([name] + aliases).map { LocalizedStationName($0) }, codes: [.sourceNative: code],
                location: location, countryCode: "XX")
    }

    private func train(_ id: String, service: String, stops: [Station], at departure: Date) -> TrainTrip {
        TrainTrip(id: RailIdentifier(rawValue: "test:history:\(id)"), source: "fixture", serviceDate: departure,
                  operatorName: "", product: service, headsign: stops.last!.displayName,
                  stopTimes: stops.enumerated().map { offset, station in
                      let time = departure.addingTimeInterval(Double(offset) * 600)
                      return StopTime(station: station, sequence: offset, scheduledArrival: time, scheduledDeparture: time)
                  },
                  capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false,
                                                     hasAlerts: false, granularity: .perStop))
    }

    private func plan(from: Station, to: Station, zone: String, at start: Date, child: TrainTrip? = nil,
                      returnService: String? = nil) -> TrackedJourneyPlan {
        func place(_ station: Station) -> RailPlace {
            RailPlace(id: station.id, kind: .station, displayName: station.displayName, context: "", countryCode: "XX",
                      timeZoneIdentifier: zone, location: station.location, eligibleModes: [], attributions: [])
        }
        let origin = place(from)
        let destination = place(to)
        let end = start.addingTimeInterval(1200)
        let outward = JourneyPlanSegment(id: "out", kind: .rail, from: origin, to: destination,
                                         departure: start, arrival: end, serviceName: child?.product, resolvedTripID: child?.id)
        let back = returnService.map { service in
            let time = start.addingTimeInterval(23 * 24 * 3600)
            return JourneyPlanDirection(fingerprint: "back", departure: time, arrival: time.addingTimeInterval(1200),
                                        childTripIDs: [], selectedSegments: [JourneyPlanSegment(
                                            id: "back", kind: .rail, from: destination, to: origin, serviceName: service
                                        )])
        }
        return TrackedJourneyPlan(id: UUID(), createdAt: start, origin: origin, destination: destination,
                                  outbound: JourneyPlanDirection(fingerprint: "out", departure: start, arrival: end,
                                                                 childTripIDs: child.map { [$0.id] } ?? [], selectedSegments: [outward]),
                                  returnDirection: back, preExistingChildTripIDs: [])
    }
}
