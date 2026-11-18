import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor RecordingJourneyHTTPClient: HTTPClient {
    private let response: HTTPResponse
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int = 200) {
        response = HTTPResponse(data: data, statusCode: statusCode)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

private actor SuspendingJourneyHTTPClient: HTTPClient {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await Task.sleep(for: .seconds(60))
        return HTTPResponse(data: Data("[]".utf8), statusCode: 200)
    }
}

private actor ScriptedJourneyHTTPClient: HTTPClient {
    enum Step: Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.unknown) }
        switch steps.removeFirst() {
        case let .response(response): return response
        case let .failure(code): throw URLError(code)
        }
    }
}

final class JourneySearchClientTests: XCTestCase {
    func testPlaceSearchDecodesCityAndStationFromCommittedFixture() async throws {
        let transport = RecordingJourneyHTTPClient(data: try Self.fixturePlacesData())
        let client = try Self.makeClient(transport: transport)

        let places = try await client.searchPlaces(query: "Paris Nord", limit: 20)

        XCTAssertEqual(places.map(\.kind), [.station, .city])
        XCTAssertEqual(places[0].displayName, "Paris Gare du Nord")
        XCTAssertEqual(places[0].id.rawValue, "eu:transitous:fr-paris-nord")
        XCTAssertEqual(places[1].displayName, "Paris")
        XCTAssertEqual(places[1].timeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(places[1].eligibleModes, [
            "highSpeedRail", "longDistanceRail", "nightRail", "regionalRail",
        ])
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(request.url?.path, "/v1/places/search")
        XCTAssertEqual(Self.queryValue("q", in: components), "Paris Nord")
        XCTAssertEqual(Self.queryValue("scope", in: components), "mainline")
        XCTAssertEqual(Self.queryValue("limit", in: components), "20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testDepartAtRequestUsesExplicitCriteriaOffsetAndNullCursor() async throws {
        let transport = RecordingJourneyHTTPClient(data: try Self.fixtureData())
        let client = try Self.makeClient(transport: transport)
        let criteria = JourneySearchCriteria(
            originID: RailIdentifier(rawValue: "eu:transitous:fr-paris"),
            destinationID: RailIdentifier(rawValue: "eu:transitous:nl-amsterdam"),
            requestedTime: try Self.date("2026-07-24T06:25:00Z"),
            timeZoneIdentifier: "Europe/Paris",
            arriveBy: false,
            maximumTransfers: 2,
            cursor: nil
        )

        _ = try await client.searchJourneys(criteria: criteria)

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let body = try Self.jsonObject(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url?.path, "/v1/journeys/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(body["originId"] as? String, "eu:transitous:fr-paris")
        XCTAssertEqual(body["destinationId"] as? String, "eu:transitous:nl-amsterdam")
        XCTAssertEqual(body["time"] as? String, "2026-07-24T08:25:00+02:00")
        XCTAssertEqual(body["arriveBy"] as? Bool, false)
        XCTAssertEqual(body["maxTransfers"] as? Int, 2)
        XCTAssertTrue(body["cursor"] is NSNull)
    }

    func testArriveByRequestPassesCursorAndUsesRequestedTimeZoneOffset() async throws {
        let transport = RecordingJourneyHTTPClient(data: try Self.fixtureData())
        let client = try Self.makeClient(transport: transport)
        let criteria = JourneySearchCriteria(
            originID: RailIdentifier(rawValue: "us:transitous:New_York"),
            destinationID: RailIdentifier(rawValue: "us:transitous:Washington"),
            requestedTime: try Self.date("2026-07-24T22:14:00Z"),
            timeZoneIdentifier: "America/Los_Angeles",
            arriveBy: true,
            maximumTransfers: 0,
            cursor: "journey-cursor-v1.previous.signature"
        )

        _ = try await client.searchJourneys(criteria: criteria)

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let body = try Self.jsonObject(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["time"] as? String, "2026-07-24T15:14:00-07:00")
        XCTAssertEqual(body["arriveBy"] as? Bool, true)
        XCTAssertEqual(body["maxTransfers"] as? Int, 0)
        XCTAssertEqual(body["cursor"] as? String, "journey-cursor-v1.previous.signature")
    }

    func testSearchPageDecodesExplicitDatesRailWalkCallsAndCancellation() async throws {
        let transport = RecordingJourneyHTTPClient(data: try Self.fixtureData())
        let client = try Self.makeClient(transport: transport)

        let page = try await client.searchJourneys(criteria: try Self.criteria())

        XCTAssertEqual(page.generatedAt, try Self.date("2026-07-21T19:00:00-07:00"))
        XCTAssertEqual(page.expiresAt, try Self.date("2026-07-21T19:10:00-07:00"))
        XCTAssertEqual(page.options.count, 2)
        XCTAssertEqual(page.previousCursor, "journey-cursor-v1.fixture.previous.signature")
        XCTAssertEqual(page.nextCursor, "journey-cursor-v1.fixture.next.signature")
        XCTAssertEqual(page.options[0].badges, [.direct, .fastest, .fewestChanges])

        guard case let .rail(direct) = page.options[0].segments[0] else {
            return XCTFail("Expected the fixture's first segment to be rail")
        }
        XCTAssertEqual(direct.serviceDate, try Self.date("2026-07-24T00:00:00Z"))
        XCTAssertEqual(direct.from.place.kind, .station)
        XCTAssertEqual(direct.from.city?.kind, .city)
        XCTAssertEqual(direct.from.scheduledDeparture, try Self.date("2026-07-24T08:25:00+02:00"))
        XCTAssertEqual(direct.intermediateCalls.first?.expectedPlatform, "4")

        guard case let .walk(transfer) = page.options[1].segments[1] else {
            return XCTFail("Expected the fixture's middle segment to be a walk")
        }
        XCTAssertTrue(transfer.isStationChange)
        XCTAssertEqual(transfer.duration, 600)

        guard case let .rail(cancelled) = page.options[1].segments[2] else {
            return XCTFail("Expected the fixture's final segment to be rail")
        }
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertTrue(cancelled.from.isCancelled)
        XCTAssertTrue(cancelled.to.isCancelled)
        XCTAssertNil(cancelled.tripID)
    }

    func testResolutionMapsTripsAndPreservesExplicitPartialFailures() async throws {
        let transport = RecordingJourneyHTTPClient(data: Data(Self.resolutionJSON.utf8))
        let client = try Self.makeClient(transport: transport)

        let resolution = try await client.resolvePlan(trackingTokens: ["outbound", "return"])

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let body = try Self.jsonObject(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url?.path, "/v1/journey-plans/resolve")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(body["trackingTokens"] as? [String], ["outbound", "return"])
        XCTAssertEqual(resolution.directions.count, 1)
        XCTAssertEqual(resolution.directions[0].departure, try Self.date("2026-07-24T08:25:00+02:00"))
        XCTAssertEqual(resolution.directions[0].originStationID.rawValue, "eu:transitous:fr-paris-nord")
        XCTAssertEqual(resolution.directions[0].segments.count, 3)
        let trip = try XCTUnwrap(resolution.directions[0].segments[0].trip)
        XCTAssertEqual(trip.id.rawValue, "eu:transitous:20260724-fr-eurostar-9315")
        XCTAssertEqual(trip.stopTimes.first?.expectedPlatform, "8")
        XCTAssertTrue(trip.stopTimes.last?.isCancelled == true)
        XCTAssertEqual(resolution.directions[0].segments[1].failure?.code, .notFound)
        XCTAssertEqual(resolution.directions[0].segments[2].failure?.code, .providerUnavailable)
    }

    func testResolutionWithoutCoverageIsUnconfirmedOnEverySegment() async throws {
        let client = try Self.makeClient(transport: RecordingJourneyHTTPClient(data: Data(Self.resolutionJSON.utf8)))
        let resolution = try await client.resolvePlan(trackingTokens: ["outbound"])
        XCTAssertEqual(resolution.directions[0].segments.map(\.coverage), [.unconfirmed, .unconfirmed, .unconfirmed])
    }

    func testResolutionDecodesCoverageBesideTheTripAndBesideAFailure() async throws {
        let data = try Self.resolutionData(
            tripCoverage: #"{"schemaVersion":1,"features":{"delays":{"support":"connected","availability":"observed","observedAt":"2026-07-21T18:59:30.000Z"},"position":{"support":"notProvided","availability":"notObserved","observedAt":null}}}"#,
            failureCoverage: #"{"schemaVersion":1,"features":{"delays":{"support":"unknown","availability":"unavailable"},"cancellations":{"support":"unknown","availability":"unavailable"},"platforms":{"support":"unknown","availability":"unavailable"},"position":{"support":"unknown","availability":"unavailable"}}}"#
        )
        let client = try Self.makeClient(transport: RecordingJourneyHTTPClient(data: data))

        let segments = try await client.resolvePlan(trackingTokens: ["outbound"]).directions[0].segments

        XCTAssertNotNil(segments[0].trip)
        XCTAssertEqual(segments[0].coverage[.delays].support, .connected)
        XCTAssertEqual(segments[0].coverage[.delays].availability, .observed)
        XCTAssertEqual(segments[0].coverage[.position].support, .notProvided)
        XCTAssertEqual(segments[1].coverage, .unconfirmed)
        XCTAssertEqual(segments[2].failure?.code, .providerUnavailable)
        XCTAssertTrue(segments[2].coverage.isUnavailableNow)
    }

    func testMalformedOrNewerCoverageNeverRejectsASaveableTrain() async throws {
        for coverage in ["null", "17", "[]", #""live""#, #"{"schemaVersion":9,"features":{}}"#, #"{"schemaVersion":1,"features":[1,2]}"#] {
            let data = try Self.resolutionData(tripCoverage: coverage, failureCoverage: coverage)
            let client = try Self.makeClient(transport: RecordingJourneyHTTPClient(data: data))

            let segments = try await client.resolvePlan(trackingTokens: ["outbound"]).directions[0].segments

            XCTAssertNotNil(segments[0].trip, coverage)
            XCTAssertEqual(segments[0].coverage, .unconfirmed, coverage)
            XCTAssertEqual(segments[2].coverage, .unconfirmed, coverage)
        }
    }

    func testResolutionMapsExact409ToTrackingTokenExpired() async throws {
        let transport = RecordingJourneyHTTPClient(
            data: Data(#"{"error":"tracking_token_expired"}"#.utf8),
            statusCode: 409
        )
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.resolvePlan(trackingTokens: ["expired"])) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .trackingTokenExpired)
        }
    }

    func testResolutionRejectsMalformedTripSnapshotDates() async throws {
        let malformed = try Data(Self.resolutionJSON.utf8).replacing(
            Data("2026-07-24T08:28:00+02:00".utf8),
            with: Data("not-a-trip-date".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.resolvePlan(trackingTokens: ["outbound"])) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testResolutionRejectsImpossibleTripServiceDate() async throws {
        let impossible = try Data(Self.resolutionJSON.utf8).replacing(
            Data(#""serviceDate":"2026-07-24""#.utf8),
            with: Data(#""serviceDate":"2026-02-30""#.utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: impossible)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.resolvePlan(trackingTokens: ["outbound"])) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testResolutionRejectsImpossibleTripTimestamp() async throws {
        let impossible = try Data(Self.resolutionJSON.utf8).replacing(
            Data("2026-07-24T08:28:00+02:00".utf8),
            with: Data("2026-02-30T10:00:00Z".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: impossible)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.resolvePlan(trackingTokens: ["outbound"])) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testResolutionRejectsTripTimestampWithInvalidOffsetHour() async throws {
        let malformed = try Data(Self.resolutionJSON.utf8).replacing(
            Data("2026-07-24T08:28:00+02:00".utf8),
            with: Data("2026-07-24T10:00:00+24:00".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.resolvePlan(trackingTokens: ["outbound"])) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testResolutionRejectsTripTimestampWithInvalidOffsetMinute() async throws {
        let malformed = try Data(Self.resolutionJSON.utf8).replacing(
            Data("2026-07-24T08:28:00+02:00".utf8),
            with: Data("2026-07-24T10:00:00+23:99".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.resolvePlan(trackingTokens: ["outbound"])) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testPlaceSearchServiceFailureIsNotRetried() async throws {
        let transport = RecordingJourneyHTTPClient(data: Data(#"{"error":"service_unavailable"}"#.utf8), statusCode: 503)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchPlaces(query: "Paris", limit: 10)) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .serviceUnavailable)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testJourneySearchRetriesOneTransientServiceFailure() async throws {
        let transport = ScriptedJourneyHTTPClient([
            .response(HTTPResponse(data: Data(#"{"error":"service_unavailable"}"#.utf8), statusCode: 503)),
            .response(HTTPResponse(data: try Self.fixtureData(), statusCode: 200)),
        ])
        let client = try Self.makeClient(transport: transport)

        let page = try await client.searchJourneys(criteria: try Self.criteria())

        XCTAssertEqual(page.options.count, 2)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testJourneySearchDoesNotRetryInvalidRequest() async throws {
        let transport = ScriptedJourneyHTTPClient([
            .response(HTTPResponse(data: Data(#"{"error":"invalid_request"}"#.utf8), statusCode: 400)),
        ])
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidRequest)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testJourneySearchRetriesTimeoutThenPreservesTypedFailure() async throws {
        let transport = ScriptedJourneyHTTPClient([
            .failure(.timedOut),
            .failure(.timedOut),
        ])
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .timedOut)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.timeoutInterval), [30, 30])
    }

    func testJourneySearchMapsOfflineWithoutRetry() async throws {
        let transport = ScriptedJourneyHTTPClient([
            .failure(.notConnectedToInternet),
        ])
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .offline)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMalformedResponseDateMapsToInvalidResponse() async throws {
        let malformed = try Self.fixtureData().replacing(
            Data("2026-07-21T19:00:00-07:00".utf8),
            with: Data("not-a-date".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testSearchPageRejectsImpossibleDateOnlyValue() async throws {
        let impossible = try Self.fixtureData().replacing(
            Data(#""serviceDate": "2026-07-24""#.utf8),
            with: Data(#""serviceDate": "2026-02-30""#.utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: impossible)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testSearchPageRejectsImpossibleTimestampValue() async throws {
        let impossible = try Self.fixtureData().replacing(
            Data("2026-07-21T19:00:00-07:00".utf8),
            with: Data("2026-02-30T10:00:00Z".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: impossible)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testSearchPageRejectsTimestampWithInvalidOffsetHour() async throws {
        let malformed = try Self.fixtureData().replacing(
            Data("2026-07-21T19:00:00-07:00".utf8),
            with: Data("2026-07-24T10:00:00+24:00".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testSearchPageRejectsTimestampWithInvalidOffsetMinute() async throws {
        let malformed = try Self.fixtureData().replacing(
            Data("2026-07-21T19:00:00-07:00".utf8),
            with: Data("2026-07-24T10:00:00+14:60".utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testSearchPageRejectsDateOnlyWithTrailingCombiningMark() async throws {
        let malformedDate = "2026-07-24\u{0301}"
        let malformed = try Self.fixtureData().replacing(
            Data(#""serviceDate": "2026-07-24""#.utf8),
            with: Data(#""serviceDate": "\#(malformedDate)""#.utf8)
        )
        let transport = RecordingJourneyHTTPClient(data: malformed)
        let client = try Self.makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: try Self.criteria())) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidResponse)
        }
    }

    func testInvalidTimeZoneIsRejectedBeforeTransport() async throws {
        let transport = RecordingJourneyHTTPClient(data: try Self.fixtureData())
        let client = try Self.makeClient(transport: transport)
        let invalid = JourneySearchCriteria(
            originID: RailIdentifier(rawValue: "eu:transitous:fr-paris"),
            destinationID: RailIdentifier(rawValue: "eu:transitous:nl-amsterdam"),
            requestedTime: try Self.date("2026-07-24T06:25:00Z"),
            timeZoneIdentifier: "Not/A_Time_Zone",
            arriveBy: false,
            maximumTransfers: 2,
            cursor: nil
        )

        await XCTAssertThrowsErrorAsync(try await client.searchJourneys(criteria: invalid)) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .invalidRequest)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationPropagatesFromTransport() async throws {
        let client = try Self.makeClient(transport: SuspendingJourneyHTTPClient())
        let task = Task { try await client.searchPlaces(query: "Paris", limit: 10) }
        await Task.yield()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNotConfiguredUsesClientContract() async {
        let client = JourneySearchClient(baseURL: nil, client: SuspendingJourneyHTTPClient())
        await XCTAssertThrowsErrorAsync(try await client.searchPlaces(query: "Paris", limit: 10)) { error in
            XCTAssertEqual(error as? JourneySearchClient.ClientError, .notConfigured)
        }
        Self.requireJourneySearching(client)
    }

    private static func makeClient(transport: any HTTPClient) throws -> JourneySearchClient {
        JourneySearchClient(baseURL: try XCTUnwrap(URL(string: "https://example.test")), client: transport)
    }

    private static func criteria() throws -> JourneySearchCriteria {
        JourneySearchCriteria(
            originID: RailIdentifier(rawValue: "eu:transitous:fr-paris"),
            destinationID: RailIdentifier(rawValue: "eu:transitous:nl-amsterdam"),
            requestedTime: try date("2026-07-24T06:25:00Z"),
            timeZoneIdentifier: "Europe/Paris",
            arriveBy: false,
            maximumTransfers: 2,
            cursor: nil
        )
    }

    private static func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: JourneySearchClientTests.self).url(
            forResource: "search-page",
            withExtension: "json"
        ))
        return try Data(contentsOf: url)
    }

    private static func fixturePlacesData() throws -> Data {
        let root = try jsonObject(try fixtureData())
        let options = try XCTUnwrap(root["options"] as? [[String: Any]])
        let segments = try XCTUnwrap(options.first?["segments"] as? [[String: Any]])
        let rail = try XCTUnwrap(segments.first?["rail"] as? [String: Any])
        let from = try XCTUnwrap(rail["from"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: [
            try XCTUnwrap(from["place"]),
            try XCTUnwrap(from["city"]),
        ])
    }

    private static func resolutionData(tripCoverage: String, failureCoverage: String) throws -> Data {
        try Data(resolutionJSON.utf8)
            .replacing(
                Data(#""positions":null},"failure":null}"#.utf8),
                with: Data(#""positions":null},"failure":null,"coverage":\#(tripCoverage)}"#.utf8)
            )
            .replacing(
                Data(#""message":"Trip provider unavailable"}}"#.utf8),
                with: Data(#""message":"Trip provider unavailable"},"coverage":\#(failureCoverage)}"#.utf8)
            )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value))
    }

    private static func requireJourneySearching(_ value: any JourneySearching) {}

    private static let resolutionJSON = """
    {"directions":[{"fingerprint":"journey-fingerprint-v1-paris-amsterdam-9315","originStationId":"eu:transitous:fr-paris-nord","destinationStationId":"eu:transitous:nl-amsterdam-centraal","departure":"2026-07-24T08:25:00+02:00","arrival":"2026-07-24T12:14:00+02:00","segments":[
      {"segmentId":"segment-eurostar-9315","trip":{"id":"eu:transitous:20260724-fr-eurostar-9315","source":"transitous","serviceDate":"2026-07-24","operatorName":"Eurostar","product":"Eurostar","headsign":"Amsterdam Centraal","fetchedAt":"2026-07-21T19:00:00.000Z","stops":[
        {"stationId":"eu:transitous:fr-paris-nord","stationName":"Paris Gare du Nord","countryCode":"FR","latitude":48.880947,"longitude":2.355314,"sequence":1,"scheduledArrival":null,"scheduledDeparture":"2026-07-24T08:25:00+02:00","expectedArrival":null,"expectedDeparture":"2026-07-24T08:28:00+02:00","plannedPlatform":"7","expectedPlatform":"8","cancelled":false,"passed":false},
        {"stationId":"eu:transitous:nl-amsterdam-centraal","stationName":"Amsterdam Centraal","countryCode":"NL","latitude":52.379128,"longitude":4.900272,"sequence":2,"scheduledArrival":"2026-07-24T12:14:00+02:00","scheduledDeparture":null,"expectedArrival":"2026-07-24T12:17:00+02:00","expectedDeparture":null,"plannedPlatform":"15b","expectedPlatform":"15b","cancelled":true,"passed":false}
      ],"positions":null},"failure":null},
      {"segmentId":"missing","trip":null,"failure":{"code":"not_found","message":"Trip not found"}},
      {"segmentId":"offline","trip":null,"failure":{"code":"provider_unavailable","message":"Trip provider unavailable"}}
    ]}]}
    """
}

private extension Data {
    func replacing(_ target: Data, with replacement: Data) throws -> Data {
        guard let range = range(of: target) else { throw CocoaError(.fileReadCorruptFile) }
        var value = self
        value.replaceSubrange(range, with: replacement)
        return value
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        handler(error)
    }
}
