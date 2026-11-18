import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyPlanSelectedSegmentTests: XCTestCase {
    func testSaveJoinsResolutionByIDAndPreservesUnsupportedAndWalkingLegs() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let first = rail(id: "first", trip: trips[0], boarding: 1, alighting: 3)
        let unsupported = rail(id: "unsupported", trip: trips[0], isTrackable: false)
        let last = rail(id: "last", trip: trips[1])
        let walk = WalkJourneySegment(
            id: "walk", from: unsupported.to.place, to: last.from.place,
            duration: 480, distance: 600, isStationChange: true
        )
        let selected = option(id: "outbound", segments: [.rail(first), .rail(unsupported), .walk(walk), .rail(last)])
        let resolution = resolved(selected, segments: [
            .init(segmentID: last.id, trip: trips[1], failure: nil),
            .init(segmentID: first.id, trip: trips[0], failure: nil)
        ])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let archive = JourneyPlanArchive(defaults: context.defaults, key: "selectedPlans")
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: archive)

        let plan = try library.track(draft: draft(outbound: selected), resolution: .init(directions: [resolution]))
        let saved = try XCTUnwrap(plan.outbound.selectedSegments)

        XCTAssertEqual(saved.map(\.id), [first.id, unsupported.id, walk.id, last.id])
        XCTAssertEqual(saved.map(\.resolvedTripID), [trips[0].id, nil, nil, trips[1].id])
        XCTAssertEqual(saved[0].from.id, trips[0].stopTimes[1].station.id)
        XCTAssertEqual(saved[0].to.id, trips[0].stopTimes[3].station.id)
        XCTAssertNotEqual(saved[0].from.id, trips[0].stopTimes.first?.station.id)
        XCTAssertNotEqual(saved[0].to.id, trips[0].stopTimes.last?.station.id)
        XCTAssertEqual(saved[0].departure, first.from.scheduledDeparture)
        XCTAssertEqual(saved[0].arrival, first.to.scheduledArrival)
        XCTAssertNotEqual(saved[0].departure, first.from.expectedDeparture)
        XCTAssertEqual(saved[1].unavailableReason, "Provider does not support tracking.")
        XCTAssertEqual(saved[2].kind, .walk)
        XCTAssertEqual(saved[2].duration, 480)
        XCTAssertTrue(saved[2].isStationChange)
        XCTAssertNil(saved[2].departure)
        XCTAssertNil(saved[2].arrival)
        XCTAssertEqual(try archive.load(), [plan])
        let stored = try XCTUnwrap(context.defaults.data(forKey: "selectedPlans"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("private-tracking-token"))
    }

    func testRoundTripKeepsTheSelectedEndpointsForEachDirection() throws {
        let trips = JourneyPlanTestFixtures.makeTrips()
        let outbound = option(id: "outbound", segments: [.rail(rail(id: "out", trip: trips[0]))])
        let returning = option(id: "return", segments: [.rail(rail(id: "back", trip: trips[1]))])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())

        let plan = try library.track(draft: draft(outbound: outbound, returning: returning), resolution: .init(directions: [
            resolved(outbound, segments: [.init(segmentID: "out", trip: trips[0], failure: nil)]),
            resolved(returning, segments: [.init(segmentID: "back", trip: trips[1], failure: nil)])
        ]))

        XCTAssertEqual(plan.outbound.selectedSegment(for: trips[0].id)?.id, "out")
        XCTAssertEqual(plan.returnDirection?.selectedSegment(for: trips[1].id)?.id, "back")
        XCTAssertNil(plan.outbound.selectedSegment(for: trips[1].id))
        XCTAssertNil(plan.returnDirection?.selectedSegment(for: trips[0].id))
    }

    func testRepeatedFullTripKeepsBothSelectedLegsAndReportsAmbiguity() throws {
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let selected = option(id: "outbound", segments: [
            .rail(rail(id: "first-use", trip: trip, boarding: 0, alighting: 1)),
            .rail(rail(id: "second-use", trip: trip, boarding: 2, alighting: 3))
        ])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())

        let plan = try library.track(draft: draft(outbound: selected), resolution: .init(directions: [
            resolved(selected, segments: [
                .init(segmentID: "first-use", trip: trip, failure: nil),
                .init(segmentID: "second-use", trip: trip, failure: nil)
            ])
        ]))

        XCTAssertEqual(plan.outbound.childTripIDs, [trip.id])
        XCTAssertEqual(plan.outbound.selectedSegments?.count, 2)
        XCTAssertEqual(plan.outbound.ambiguousTripIDs, [trip.id])
        XCTAssertNil(plan.outbound.selectedSegment(for: trip.id))
    }

    func testFailedResolutionPreservesChosenRailWithoutClaimingItIsTracked() throws {
        let trip = JourneyPlanTestFixtures.makeTrips()[0]
        let selected = option(id: "outbound", segments: [.rail(rail(id: "failed", trip: trip))])
        let context = try JourneyPlanTestFixtures.makeTripLibrary()
        defer { context.cleanup() }
        let library = try JourneyPlanLibrary(tripLibrary: context.library, archive: RecordingJourneyPlanArchive())

        let plan = try library.track(draft: draft(outbound: selected), resolution: .init(directions: [
            resolved(selected, segments: [.init(segmentID: "failed", trip: nil, failure: .init(
                code: .providerUnavailable, message: "Live tracking is temporarily unavailable."
            ))])
        ]))

        let saved = try XCTUnwrap(plan.outbound.selectedSegments?.first)
        XCTAssertEqual(saved.id, "failed")
        XCTAssertNil(saved.resolvedTripID)
        XCTAssertEqual(saved.unavailableReason, "Live tracking is temporarily unavailable.")
        XCTAssertTrue(plan.outbound.childTripIDs.isEmpty)
    }

    private func rail(
        id: String, trip: TrainTrip, boarding: Int = 0, alighting: Int? = nil,
        isTrackable: Bool = true
    ) -> RailJourneySegment {
        RailJourneySegment(
            id: id, tripID: trip.id, serviceDate: trip.serviceDate,
            operatorName: trip.operatorName, product: trip.product, trainNumber: nil, trainName: nil,
            from: call(trip.stopTimes[boarding]),
            to: call(trip.stopTimes[alighting ?? (trip.stopTimes.count - 1)]),
            intermediateCalls: [], isCancelled: false, isRealtime: true,
            isTrackable: isTrackable,
            untrackableReason: isTrackable ? nil : "Provider does not support tracking."
        )
    }

    private func call(_ stop: StopTime) -> JourneyCall {
        JourneyCall(
            place: RailPlace(
                id: stop.station.id, kind: .station, displayName: stop.station.displayName,
                context: "", countryCode: stop.station.countryCode,
                timeZoneIdentifier: "America/New_York", location: stop.station.location,
                eligibleModes: ["longDistanceRail"], attributions: []
            ),
            city: nil, scheduledArrival: stop.scheduledArrival, scheduledDeparture: stop.scheduledDeparture,
            expectedArrival: stop.expectedArrival, expectedDeparture: stop.expectedDeparture,
            plannedPlatform: stop.plannedPlatform, expectedPlatform: stop.expectedPlatform, isCancelled: false
        )
    }

    private func option(id: String, segments: [JourneySegment]) -> JourneyOption {
        JourneyOption(
            id: id, fingerprint: id, startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 1_000), duration: 900, transferCount: 0,
            segments: segments, badges: [],
            trackability: .init(trackableRailSegments: 1, totalRailSegments: 1),
            realtimeFreshness: nil, attributions: [], trackingToken: "private-tracking-token"
        )
    }

    private func draft(outbound: JourneyOption, returning: JourneyOption? = nil) -> JourneyPlanDraft {
        let fixture = JourneyPlanTestFixtures.makeDraft()
        return JourneyPlanDraft(
            id: fixture.id, origin: fixture.origin, destination: fixture.destination,
            outbound: outbound, returnOption: returning
        )
    }

    private func resolved(
        _ option: JourneyOption, segments: [JourneyPlanResolution.Segment]
    ) -> JourneyPlanResolution.Direction {
        let fixture = JourneyPlanTestFixtures.makeDraft()
        return .init(
            fingerprint: option.fingerprint, originStationID: fixture.origin.id,
            destinationStationID: fixture.destination.id, departure: option.startTime,
            arrival: option.endTime, segments: segments
        )
    }
}
