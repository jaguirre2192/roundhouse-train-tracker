import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class SrbijavozSourceTests: XCTestCase {
    func testOfficialScheduleMapsWithoutRealtimeClaimsAndKeepsItsOriginalFetchDate() throws {
        let snapshot = try SrbijavozSourceFixture.snapshot()
        XCTAssertTrue(snapshot.hasValidWireDates)
        let trip = snapshot.trip
        assertScheduleOnly(trip)
        XCTAssertEqual(trip.sourceFetchedAt, SrbijavozSourceFixture.fetchedAt)
        let restored = try JSONDecoder().decode(TrainTrip.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(restored, trip)
        assertScheduleOnly(snapshot.merging(into: restored))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as? [String: Any])
        legacy.removeValue(forKey: "sourceFetchedAt")
        let legacyTrip = try JSONDecoder().decode(TrainTrip.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyTrip.sourceFetchedAt, "Archives from earlier versions remain readable")
    }

    func testSavedScheduleReloadsAndRefreshesThroughBackendWithoutAdvancingOriginalCheck() async throws {
        let suite = "SrbijavozSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = TripArchive(defaults: defaults)
        let transport = SrbijavozSourceHTTPClient()
        let backend = TripSnapshotBackendClient(baseURL: SrbijavozSourceFixture.baseURL, client: transport)
        let original = makeLibrary(trips: [], backend: backend, archive: archive)
        let trip = try SrbijavozSourceFixture.snapshot().trip
        XCTAssertTrue(try original.storeTrackedTrip(trip))
        let reloaded = makeLibrary(trips: nil, backend: backend, archive: archive)
        XCTAssertEqual(reloaded.trips, [trip])

        await reloaded.refreshTrackedTrip(id: trip.id)

        let refreshed = try XCTUnwrap(reloaded.trip(id: trip.id))
        assertScheduleOnly(refreshed)
        XCTAssertEqual(refreshed.sourceFetchedAt, SrbijavozSourceFixture.fetchedAt)
        XCTAssertEqual(reloaded.lastSuccessfulCheck(for: trip.id), SrbijavozSourceFixture.fetchedAt)
        XCTAssertFalse(reloaded.lastRefreshFailed(for: trip.id))
        XCTAssertEqual(archive.load(), [refreshed])
        XCTAssertEqual(archive.loadLastChecks()[trip.id], SrbijavozSourceFixture.fetchedAt)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(request.url?.path, "/v1/trips/snapshot")
        XCTAssertEqual(query.first { $0.name == "source" }?.value, "srbijavoz")
        XCTAssertEqual(query.first { $0.name == "id" }?.value, trip.id.rawValue)
        XCTAssertEqual(query.first { $0.name == "nativeId" }?.value, trip.id.nativeID)
        XCTAssertEqual(query.first { $0.name == "serviceDate" }?.value, "2026-11-14")
        let progress = RailJourneyProgress(trip: refreshed, referenceDate: SrbijavozSourceFixture.now)
        let freshness = TripFreshness(lastSuccessfulCheck: reloaded.lastSuccessfulCheck(for: trip.id), lastRefreshFailed: false)
        XCTAssertEqual(JourneyTrust(freshness: freshness, timingBasis: progress.timingBasis,
                                   phase: progress.phase, referenceDate: SrbijavozSourceFixture.now), .timetable)
        XCTAssertFalse(freshness.text(at: SrbijavozSourceFixture.now).contains("just now"))
    }

    func testBackendFailureOrMissingConfigurationPreservesSavedSerbianSchedule() async throws {
        let trip = try SrbijavozSourceFixture.snapshot().trip
        for configured in [true, false] {
            let transport = SrbijavozSourceHTTPClient(statusCode: 503)
            let backend = TripSnapshotBackendClient(baseURL: configured ? SrbijavozSourceFixture.baseURL : nil, client: transport)
            let library = makeLibrary(trips: [trip], backend: backend)
            await library.refreshTrackedTrip(id: trip.id)
            XCTAssertTrue(library.lastRefreshFailed(for: trip.id))
            XCTAssertNil(library.lastSuccessfulCheck(for: trip.id))
            XCTAssertEqual(library.trips, [trip])

            do {
                _ = try await library.board(stationID: XCTUnwrap(trip.origin?.id), source: .europe,
                                            at: SrbijavozSourceFixture.now)
                XCTFail("A failed official board must remain a failure")
            } catch {}
            do {
                try await library.addTrip(StopTimeSummary(
                    tripID: trip.id, serviceDate: trip.serviceDate, stopTime: XCTUnwrap(trip.stopTimes.first),
                    headsign: trip.headsign, product: trip.product
                ), source: .europe)
                XCTFail("A failed official trip fetch must remain a failure")
            } catch {}
        }
    }

    func testPushReferencePreservesOfficialSourceAndNativeStationIDs() async throws {
        let transport = SrbijavozSourceHTTPClient(statusCode: 204)
        let client = PushBackendClient(baseURL: SrbijavozSourceFixture.baseURL, client: transport,
                                       credential: { String(repeating: "s", count: 43) })
        let trip = try SrbijavozSourceFixture.snapshot().trip
        try await client.subscribe(.init(installationID: UUID(), trip: trip))
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let reference = try XCTUnwrap(body["trip"] as? [String: Any])
        XCTAssertEqual(reference["source"] as? String, "srbijavoz")
        XCTAssertEqual(reference["id"] as? String, trip.id.rawValue)
        XCTAssertEqual(reference["nativeId"] as? String, trip.id.nativeID)
        XCTAssertEqual(body["boardingStationId"] as? String, "rs:srbijavoz:16052")
        XCTAssertEqual(body["alightingStationId"] as? String, "rs:srbijavoz:16807")
    }

    func testMalformedSnapshotDatesCannotBecomeFreshChecks() async throws {
        let transport = SrbijavozSourceHTTPClient(json: SrbijavozSourceFixture.json
            .replacingOccurrences(of: "2026-11-13T18:00:00Z", with: "not-a-date"))
        let backend = TripSnapshotBackendClient(baseURL: SrbijavozSourceFixture.baseURL, client: transport)
        let trip = try SrbijavozSourceFixture.snapshot().trip
        do {
            _ = try await backend.enrichedTrip(trip)
            XCTFail("An invalid original fetch date must fail validation")
        } catch TripSnapshotBackendClient.ClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func assertScheduleOnly(_ trip: TrainTrip, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(trip.capabilities.hasRealtimeDelays, file: file, line: line)
        XCTAssertFalse(trip.capabilities.hasPlatforms, file: file, line: line)
        XCTAssertFalse(trip.capabilities.hasPositions, file: file, line: line)
        XCTAssertFalse(trip.capabilities.hasAlerts, file: file, line: line)
        XCTAssertTrue(trip.positions.isEmpty, file: file, line: line)
        XCTAssertFalse(trip.isCancelled, file: file, line: line)
        for stop in trip.stopTimes {
            XCTAssertNil(stop.expectedArrival, file: file, line: line)
            XCTAssertNil(stop.expectedDeparture, file: file, line: line)
            XCTAssertNil(stop.plannedPlatform, file: file, line: line)
            XCTAssertNil(stop.expectedPlatform, file: file, line: line)
        }
        XCTAssertEqual(RailJourneyProgress(trip: trip, referenceDate: SrbijavozSourceFixture.now).timingBasis,
                       .scheduled, file: file, line: line)
        XCTAssertEqual(TripPresentationStatus(trip: trip, referenceDate: SrbijavozSourceFixture.now).kind,
                       .scheduled, file: file, line: line)
    }

    private func makeLibrary(trips: [TrainTrip]?, backend: TripSnapshotBackendClient,
                             archive: TripArchive? = nil) -> TripLibrary {
        TripLibrary(trips: trips, backendSnapshots: backend, pushCoordinator: RecordingPushCoordinator(),
                    archive: archive, automaticRefreshEnabled: true,
                    now: { SrbijavozSourceFixture.now })
    }
}
