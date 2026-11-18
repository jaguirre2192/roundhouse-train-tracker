import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class MeetTrainTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_795_019_400)

    func testBookedAlightingIsIntermediateAndStandaloneRideRequiresChoice() throws {
        let trip = TripUpdatesQA.amtrak.snapshot(.baseline, now: time)
        let section = RiddenTrainSection(trip: trip)
        let plan = try XCTUnwrap(section.plan(on: trip, from: trip.stopTimes[0].id, to: trip.stopTimes[1].id, at: time, knownPlans: []))
        let segment = try XCTUnwrap(plan.outbound.selectedSegment(for: trip.id))
        let booked = MeetTrainSelection(trip: trip, segment: segment, watching: false, at: time)
        XCTAssertEqual(booked.bookedCall?.id, trip.stopTimes[1].id)
        XCTAssertEqual(booked.calls.map(\.id), [trip.stopTimes[1].id])
        let standalone = MeetTrainSelection(trip: trip, segment: nil, watching: false, at: time)
        XCTAssertNil(standalone.bookedCall)
        XCTAssertEqual(standalone.calls.map(\.id), [trip.stopTimes[1].id, trip.stopTimes[2].id])
        XCTAssertTrue(MeetTrainSelection(trip: trip, segment: segment, watching: true, at: time).calls.isEmpty)
    }

    func testPostContainsOnlyTheSelectedCallAndNoSensitiveItinerary() async throws {
        let trip = TripUpdatesQA.amtrak.snapshot(.baseline, now: time), stop = trip.stopTimes[1]
        let client = MeetRecordingHTTP()
        let sharing = TripSharingClient(baseURL: URL(string: "https://roundhouse.test"), client: client)
        let link = try await sharing.createArrivalBoard(for: trip, stop: stop, zone: TimeZone(identifier: "America/New_York"), note: "  By the clock  ")
        XCTAssertEqual(link.url.path, "/meet")
        let last = await client.last
        let request = try XCTUnwrap(last)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/v1/arrival-boards")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["trip", "stationId", "sequence", "timeZone", "note"])
        XCTAssertEqual(body["stationId"] as? String, "us:amtraker:BAL", "Native IDs in older archives must select the canonical backend call")
        XCTAssertEqual(body["sequence"] as? Int, stop.sequence)
        XCTAssertEqual(body["note"] as? String, "By the clock")
        XCTAssertNil(TripSharingClient.token(from: link.url))
    }

    func testUntrustedRedirectCannotLeaveTheComposer() async throws {
        let trip = TripUpdatesQA.amtrak.snapshot(.baseline, now: time)
        let sharing = TripSharingClient(baseURL: URL(string: "https://roundhouse.test"), client: MeetRecordingHTTP(host: "unrelated.test"))
        do {
            _ = try await sharing.createArrivalBoard(for: trip, stop: trip.stopTimes[1], zone: nil, note: "")
            XCTFail("A server response cannot redirect the rider’s share to another website")
        } catch TripSharingClient.ArrivalError.invalidLink {}
    }
}

private actor MeetRecordingHTTP: HTTPClient {
    let host: String
    var last: URLRequest?
    init(host: String = "roundhouse.test") { self.host = host }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        last = request
        return HTTPResponse(data: try JSONEncoder().encode([
            "url": "https://" + host + "/meet#" + String(repeating: "a", count: 43),
            "expiresAt": "2026-11-19T01:00:00.000Z",
        ]), statusCode: 201)
    }
}
