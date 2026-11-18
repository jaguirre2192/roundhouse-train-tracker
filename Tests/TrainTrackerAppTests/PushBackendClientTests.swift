import Foundation
import TrainTrackerCore
import XCTest

@testable import TrainTracker

private actor RecordingPushHTTPClient: HTTPClient {
  private let statusCode: Int
  private let body: Data
  private(set) var requests: [URLRequest] = []

  init(statusCode: Int = 204, body: String = "") {
    self.statusCode = statusCode
    self.body = Data(body.utf8)
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return HTTPResponse(data: body, statusCode: statusCode)
  }
}

final class PushBackendClientTests: XCTestCase {
  func testRegistrationSendsPossessionCredentialAndBoundedBody() async throws {
    let transport = RecordingPushHTTPClient()
    let credential = String(repeating: "c", count: 43)
    let client = PushBackendClient(
      baseURL: try XCTUnwrap(URL(string: "https://example.test")),
      client: transport,
      credential: { credential }
    )
    let installationID = try XCTUnwrap(
      UUID(
        uuidString: "BA141C63-E992-48ED-8C46-86CB6D42586A"
      ))

    try await client.registerDevice(
      token: Data(repeating: 0xab, count: 32),
      installationID: installationID,
      environment: .production,
      platform: .ios
    )

    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/v1/devices")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Device \(credential)")
    XCTAssertLessThan(try XCTUnwrap(request.httpBody).count, 16 * 1_024)
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
    )
    XCTAssertEqual(body["installationId"] as? String, installationID.uuidString.lowercased())
    XCTAssertEqual(body["token"] as? String, String(repeating: "ab", count: 32))
  }

  func testUnsubscribeUsesSamePossessionCredential() async throws {
    let transport = RecordingPushHTTPClient()
    let credential = String(repeating: "u", count: 43)
    let client = PushBackendClient(
      baseURL: try XCTUnwrap(URL(string: "https://example.test")),
      client: transport,
      credential: { credential }
    )
    let installationID = try XCTUnwrap(
      UUID(
        uuidString: "BA141C63-E992-48ED-8C46-86CB6D42586A"
      ))

    try await client.unsubscribe(
      installationID: installationID,
      tripID: RailIdentifier(rawValue: "us:amtraker:171-20")
    )

    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Device \(credential)")
    let components = try XCTUnwrap(
      URLComponents(
        url: try XCTUnwrap(request.url),
        resolvingAgainstBaseURL: false
      ))
    XCTAssertEqual(
      components.queryItems?.first { $0.name == "installationId" }?.value,
      installationID.uuidString.lowercased()
    )
    XCTAssertEqual(
      components.queryItems?.first { $0.name == "tripId" }?.value,
      "us:amtraker:171-20"
    )
  }

  @MainActor
  func testSubscribeSendsRiderStopsAndFallsBackToWholeTrainForForeignStations() async throws {
    let trip = JourneyPlanTestFixtures.makeTrips()[0]
    let transport = RecordingPushHTTPClient()
    let client = try makeClient(transport)
    let installationID = UUID()

    try await client.subscribe(.init(
      installationID: installationID, trip: trip,
      boardingStationID: trip.stopTimes[1].station.id,
      alightingStationID: trip.stopTimes[2].station.id
    ))
    try await client.subscribe(.init(
      installationID: installationID, trip: trip,
      boardingStationID: RailIdentifier(rawValue: "not:on:this:train"),
      alightingStationID: trip.stopTimes[2].station.id
    ))

    let bodies = try await transport.requests.map { request in
      try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    XCTAssertEqual(bodies[0]["boardingStationId"] as? String, trip.stopTimes[1].station.id.rawValue)
    XCTAssertEqual(bodies[0]["alightingStationId"] as? String, trip.stopTimes[2].station.id.rawValue)
    XCTAssertEqual(bodies[1]["boardingStationId"] as? String, trip.origin?.id.rawValue)
    XCTAssertEqual(bodies[1]["alightingStationId"] as? String, trip.destination?.id.rawValue)
  }

  @MainActor
  func testAlertRangeUsesSelectedSegmentStopsFromTheTrip() throws {
    let trip = JourneyPlanTestFixtures.makeTrips()[0]
    let segment = JourneyPlanSegment(
      id: "leg", kind: .rail,
      from: Self.place(trip.stopTimes[1].station), to: Self.place(trip.stopTimes[3].station),
      resolvedTripID: trip.id
    )
    let range = try XCTUnwrap(TripAlertRange(trip: trip, segment: segment))
    XCTAssertEqual(range.boardingStationID, trip.stopTimes[1].station.id)
    XCTAssertEqual(range.alightingStationID, trip.stopTimes[3].station.id)

    let otherTrain = JourneyPlanSegment(
      id: "other", kind: .rail,
      from: Self.place(trip.stopTimes[1].station), to: Self.place(trip.stopTimes[3].station),
      resolvedTripID: RailIdentifier(rawValue: "another-train")
    )
    XCTAssertEqual(TripAlertRange(trip: trip, segment: otherTrain)?.boardingStationID, trip.origin?.id)
  }

  @MainActor
  func testTripWithoutStopsFailsInsteadOfLookingSubscribed() async throws {
    let template = JourneyPlanTestFixtures.makeTrips()[0]
    let trip = TrainTrip(
      id: template.id, source: template.source, serviceDate: template.serviceDate,
      operatorName: template.operatorName, product: template.product, headsign: template.headsign,
      stopTimes: [], positions: [], alerts: [], capabilities: template.capabilities
    )
    let transport = RecordingPushHTTPClient()
    let client = try makeClient(transport)
    do {
      try await client.subscribe(.init(installationID: UUID(), trip: trip))
      XCTFail("A train without stops must not report success")
    } catch PushBackendClient.ClientError.tripRejected(.invalidTrip) {}
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }

  @MainActor
  func testSubscriptionRejectionsAreScopedToTheTrain() async throws {
    let trip = JourneyPlanTestFixtures.makeTrips()[0]
    let cases: [(Int, String, PushBackendClient.ClientError)] = [
      (409, #"{"error":"quota_exceeded"}"#, .tripRejected(.quotaExceeded)),
      (409, #"{"error":"trip_conflict"}"#, .tripRejected(.tripConflict)),
      (400, #"{"error":"invalid_request"}"#, .tripRejected(.invalidTrip)),
      (409, #"{"error":"token_conflict"}"#, .rejected(409)),
      (401, #"{"error":"unauthorized"}"#, .rejected(401)),
    ]
    for (status, body, expected) in cases {
      let client = try makeClient(RecordingPushHTTPClient(statusCode: status, body: body))
      do {
        try await client.subscribe(.init(installationID: UUID(), trip: trip))
        XCTFail("HTTP \(status) must fail")
      } catch let error as PushBackendClient.ClientError {
        XCTAssertEqual(String(describing: error), String(describing: expected), body)
      }
    }
  }

  private func makeClient(_ transport: RecordingPushHTTPClient) throws -> PushBackendClient {
    PushBackendClient(
      baseURL: try XCTUnwrap(URL(string: "https://example.test")),
      client: transport,
      credential: { String(repeating: "c", count: 43) }
    )
  }

  private static func place(_ station: Station) -> RailPlace {
    RailPlace(
      id: station.id, kind: .station, displayName: station.displayName, context: "",
      countryCode: station.countryCode, timeZoneIdentifier: "Europe/Paris",
      location: station.location, eligibleModes: [], attributions: []
    )
  }
}
