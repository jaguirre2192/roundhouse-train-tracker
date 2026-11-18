import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

private actor RecordingLiveActivityHTTPClient: HTTPClient {
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int = 204) { self.statusCode = statusCode }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(data: Data(), statusCode: statusCode)
    }
}

@MainActor
final class LiveActivityRegistrationTests: XCTestCase {
    func testManagerRetiresActivitiesOwnedByThePreviousInstallationWithoutSendingRemoval() async throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveActivityRegistrationStore(defaults: defaults)
        _ = store.generation(for: "activity-123", token: Data([1]))
        let backend = RecordingLiveActivityBackend()
        var localEnds: [String] = []
        let manager = TrainLiveActivityManager(
            backend: backend, registrations: store,
            existingActivityIDs: { ["activity-123", "activity-without-token"] },
            retireActivity: { localEnds.append($0) }
        )

        defaults.set(UUID().uuidString, forKey: "pushInstallationID")
        LiveActivityRegistrationStore.resetInstallationRecords(in: defaults)
        await manager.resume()

        XCTAssertEqual(Set(localEnds), ["activity-123", "activity-without-token"])
        XCTAssertNil(store.generation(for: "activity-123", token: Data([2])))
        let serverEnds = await backend.endedIDs()
        XCTAssertTrue(serverEnds.isEmpty)
        let relaunched = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertNil(relaunched.generation(for: "activity-123", token: Data([2])))
        relaunched.markEnded("activity-123")
        XCTAssertTrue(relaunched.pendingEnds.isEmpty)
    }

    func testManagerIgnoresUploadResultsFromThePreviousInstallation() async throws {
        for oldUploadFails in [false, true] {
            let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = LiveActivityRegistrationStore(defaults: defaults)
            let oldID = store.installationID
            _ = store.generation(for: "activity-123", token: Data([1]))
            let backend = RecordingLiveActivityBackend(suspendFirstUpload: true, oldUploadFails: oldUploadFails)
            let manager = TrainLiveActivityManager(
                backend: backend, registrations: store,
                existingActivityIDs: { ["activity-123"] }, retireActivity: { _ in }
            )
            let oldRegistration = makeRegistration(installationID: oldID)
            let upload = Task { await manager.upload(oldRegistration) }
            for _ in 0..<100 {
                if await backend.registrationCount() == 1 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }

            let newID = UUID()
            defaults.set(newID.uuidString, forKey: "pushInstallationID")
            LiveActivityRegistrationStore.resetInstallationRecords(in: defaults)
            await manager.resume()
            await backend.releaseUpload()
            let oldUploadAccepted = await upload.value
            XCTAssertFalse(oldUploadAccepted)
            XCTAssertNil(manager.deliveryMessage)
            let oldRetryAccepted = await manager.upload(oldRegistration)
            XCTAssertFalse(oldRetryAccepted)
            let newUploadAccepted = await manager.upload(
                makeRegistration(installationID: newID, activityID: "new-activity")
            )
            XCTAssertTrue(newUploadAccepted)
            let count = await backend.registrationCount()
            XCTAssertEqual(count, 2)
        }
    }

    func testEnrollmentRecoveryUsesNewIdentityAndRetiresOldActivityRecords() throws {
        let suiteName = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldID = UUID()
        defaults.set(oldID.uuidString, forKey: "pushInstallationID")
        let store = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertEqual(store.generation(for: "old-activity", token: Data([1])), 1)
        store.markEnded("old-activity")

        let newID = UUID()
        defaults.set(newID.uuidString, forKey: "pushInstallationID")

        XCTAssertEqual(store.installationID, newID)
        XCTAssertTrue(store.knownActivityIDs.isEmpty)
        XCTAssertTrue(store.pendingEnds.isEmpty)
        XCTAssertNil(store.generation(for: "old-activity", token: Data([3])))
        store.markEnded("old-activity")
        XCTAssertTrue(store.pendingEnds.isEmpty)
        XCTAssertEqual(store.generation(for: "new-activity", token: Data([2])), 1)
        let relaunched = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertEqual(relaunched.installationID, newID)
        XCTAssertEqual(relaunched.knownActivityIDs, ["new-activity"])
        XCTAssertNil(relaunched.generation(for: "old-activity", token: Data([3])))
        relaunched.markEnded("old-activity")
        XCTAssertTrue(relaunched.pendingEnds.isEmpty)
    }

    func testRegistrationSendsSelectedLegWithPossessionCredentialAndUnixContentTimes() async throws {
        let transport = RecordingLiveActivityHTTPClient()
        let credential = String(repeating: "c", count: 43)
        let client = LiveActivityBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")), client: transport,
            credential: { credential }
        )
        let installationID = try XCTUnwrap(UUID(uuidString: "BA141C63-E992-48ED-8C46-86CB6D42586A"))
        let registration = makeRegistration(installationID: installationID, isRiding: false)

        try await client.register(registration)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/v1/live-activities")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Device \(credential)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 20)
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["schemaVersion"] as? Int, 1)
        XCTAssertEqual(body["installationId"] as? String, installationID.uuidString.lowercased())
        XCTAssertEqual(body["activityId"] as? String, "activity-123")
        XCTAssertEqual(body["token"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(body["tokenGeneration"] as? Int, 3)
        XCTAssertEqual(body["environment"] as? String, "production")
        XCTAssertEqual(body["boardingStationId"] as? String, "us:station:NYP")
        XCTAssertEqual(body["alightingStationId"] as? String, "us:station:BOS")
        XCTAssertEqual(body["boardingStopSequence"] as? Int, 1)
        XCTAssertEqual(body["isRiding"] as? Bool, false)
        XCTAssertEqual(body["alightingStopSequence"] as? Int, 2)
        XCTAssertEqual(body["startedAt"] as? String, "2026-09-15T22:10:00Z")
        let trip = try XCTUnwrap(body["trip"] as? [String: Any])
        XCTAssertEqual(trip["id"] as? String, "us:amtrak:2162")
        XCTAssertEqual(trip["nativeId"] as? String, "2162")
        XCTAssertEqual(trip["source"] as? String, "amtrak")
        XCTAssertEqual(trip["serviceDate"] as? String, "2026-09-15")
        let state = try XCTUnwrap(body["initialContentState"] as? [String: Any])
        XCTAssertEqual(state["eventTime"] as? Double, registration.initialContentState.eventTime)
        XCTAssertEqual(state["checkedAt"] as? Double, registration.initialContentState.checkedAt)
        XCTAssertEqual(state["validUntil"] as? Double, registration.initialContentState.validUntil)
        XCTAssertNil(body["credential"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(credential))
    }

    func testEndUsesDeleteIdentityAndTheSamePossessionCredential() async throws {
        let transport = RecordingLiveActivityHTTPClient()
        let credential = String(repeating: "d", count: 43)
        let client = LiveActivityBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")), client: transport,
            credential: { credential }
        )
        let installationID = try XCTUnwrap(UUID(uuidString: "BA141C63-E992-48ED-8C46-86CB6D42586A"))

        try await client.end(activityID: "activity-123", installationID: installationID)

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/live-activities/activity-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Device \(credential)")
        XCTAssertNil(request.httpBody)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "installationId", value: installationID.uuidString.lowercased()),
        ])
    }

    func testRejectedRegistrationAndEndRemainFailures() async throws {
        for statusCode in [409, 503] {
            let transport = RecordingLiveActivityHTTPClient(statusCode: statusCode)
            let client = LiveActivityBackendClient(
                baseURL: try XCTUnwrap(URL(string: "https://example.test")), client: transport,
                credential: { String(repeating: "x", count: 43) }
            )
            let installationID = UUID()
            do {
                try await client.register(makeRegistration(installationID: installationID))
                XCTFail("HTTP \(statusCode) must not count as registration")
            } catch LiveActivityBackendClient.ClientError.rejected(let actual) {
                XCTAssertEqual(actual, statusCode)
            }
            do {
                try await client.end(activityID: "activity-123", installationID: installationID)
                XCTFail("HTTP \(statusCode) must not acknowledge an end")
            } catch LiveActivityBackendClient.ClientError.rejected(let actual) {
                XCTAssertEqual(actual, statusCode)
            }
        }
    }

    func testUnauthorizedRegistrationAndEndAreReportedDistinctly() async throws {
        let client = LiveActivityBackendClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test")),
            client: RecordingLiveActivityHTTPClient(statusCode: 401),
            credential: { String(repeating: "x", count: 43) }
        )
        do {
            try await client.register(makeRegistration(installationID: UUID()))
            XCTFail("HTTP 401 must not count as registration")
        } catch LiveActivityBackendClient.ClientError.unauthorized {}
        do {
            try await client.end(activityID: "activity-123", installationID: UUID())
            XCTFail("HTTP 401 must not acknowledge an end")
        } catch LiveActivityBackendClient.ClientError.unauthorized {}
    }

    func testUnauthorizedUploadAsksForInstallationReplacement() async throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveActivityRegistrationStore(defaults: defaults)
        let manager = TrainLiveActivityManager(
            backend: RecordingLiveActivityBackend(registrationError: .unauthorized), registrations: store,
            existingActivityIDs: { [] }, retireActivity: { _ in }
        )
        var rejections = 0
        manager.installationRejectionHandler = { rejections += 1 }

        let accepted = await manager.upload(makeRegistration(installationID: store.installationID))

        XCTAssertFalse(accepted)
        XCTAssertEqual(rejections, 1)
    }

    func testReplacedInstallationKeepsRunningActivitiesRegistrable() async throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveActivityRegistrationStore(defaults: defaults)
        _ = store.generation(for: "running", token: Data([1]))
        store.markEnded("finished")
        var localEnds: [String] = []
        let manager = TrainLiveActivityManager(
            backend: RecordingLiveActivityBackend(), registrations: store,
            existingActivityIDs: { ["running"] }, retireActivity: { localEnds.append($0) }
        )

        let newID = UUID()
        defaults.set(newID.uuidString, forKey: "pushInstallationID")
        manager.installationWasReplaced()
        await manager.resume()

        XCTAssertTrue(localEnds.isEmpty)
        XCTAssertEqual(store.installationID, newID)
        XCTAssertFalse(store.retiredActivityIDs.contains("running"))
        XCTAssertEqual(store.generation(for: "running", token: Data([1])), 1)
        XCTAssertFalse(store.pendingEnds.contains("finished"))
    }

    func testPermanentEndFailuresAreAcknowledgedAndTransientOnesBackOff() async throws {
        for (error, isPermanent) in [
            (LiveActivityBackendClient.ClientError.rejected(404), true),
            (.rejected(409), true), (.unauthorized, true), (.rejected(503), false),
        ] {
            let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = LiveActivityRegistrationStore(defaults: defaults)
            store.markEnded("ended")
            let backend = RecordingLiveActivityBackend(endError: error)
            let manager = TrainLiveActivityManager(
                backend: backend, registrations: store,
                existingActivityIDs: { [] }, retireActivity: { _ in }
            )

            await manager.resume()
            await manager.resume()

            XCTAssertEqual(store.pendingEnds.isEmpty, isPermanent, "\(error)")
            let attempts = await backend.endAttempts()
            XCTAssertEqual(attempts, 1, "\(error) must not be retried immediately")
        }
    }

    func testResumePrunesRetiredIDsForActivitiesThatNoLongerExist() async throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveActivityRegistrationStore(defaults: defaults)
        store.retireActivityIDs(["gone", "still-shown"])
        let manager = TrainLiveActivityManager(
            backend: RecordingLiveActivityBackend(), registrations: store,
            existingActivityIDs: { ["still-shown"] }, retireActivity: { _ in }
        )

        await manager.resume()

        XCTAssertEqual(Set(defaults.stringArray(forKey: "trainLiveActivityRetiredIDs.v1") ?? []), ["still-shown"])
    }

    func testUnconfiguredBackendDoesNotSendOrRequestCredentials() async throws {
        enum UnexpectedCredentialAccess: Error { case requested }
        let transport = RecordingLiveActivityHTTPClient()
        let client = LiveActivityBackendClient(
            baseURL: nil, client: transport,
            credential: { throw UnexpectedCredentialAccess.requested }
        )
        do {
            try await client.register(makeRegistration(installationID: UUID()))
            XCTFail("An unconfigured backend must reject registration")
        } catch LiveActivityBackendClient.ClientError.unavailable {}
        do {
            try await client.end(activityID: "activity-123", installationID: UUID())
            XCTFail("An unconfigured backend must retain the end request")
        } catch LiveActivityBackendClient.ClientError.unavailable {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testGenerationIsStableForRetriesAndSurvivesRelaunchAndRotation() throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = Data(repeating: 0xab, count: 32)
        let rotated = Data(repeating: 0xcd, count: 32)
        let store = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertEqual(store.generation(for: "first", token: token), 1)
        XCTAssertEqual(store.generation(for: "first", token: token), 1)
        XCTAssertEqual(store.generation(for: "second", token: token), 1)

        let relaunched = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertEqual(relaunched.installationID, store.installationID)
        XCTAssertEqual(relaunched.generation(for: "first", token: token), 1)
        XCTAssertEqual(relaunched.generation(for: "first", token: rotated), 2)
        XCTAssertEqual(relaunched.generation(for: "first", token: rotated), 2)
        XCTAssertEqual(relaunched.generation(for: "first", token: token), 3)
        XCTAssertEqual(relaunched.generation(for: "second", token: token), 1)

        let saved = try XCTUnwrap(defaults.data(forKey: "trainLiveActivityRegistrations.v1"))
        let savedText = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(savedText.contains(String(repeating: "ab", count: 32)))
        XCTAssertFalse(savedText.contains(String(repeating: "cd", count: 32)))
    }

    func testPendingEndSurvivesRelaunchBlocksTokenUpdatesAndAcknowledgesOnlyItsActivity() throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = Data(repeating: 0xab, count: 32)
        let store = LiveActivityRegistrationStore(defaults: defaults)
        _ = store.generation(for: "ended", token: token)
        _ = store.generation(for: "active", token: token)
        store.markEnded("ended")
        store.markEnded("ended-before-token")
        XCTAssertNil(store.generation(for: "ended", token: token))
        XCTAssertNil(store.generation(for: "ended-before-token", token: token))

        let relaunched = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertEqual(Set(relaunched.pendingEnds), ["ended", "ended-before-token"])
        XCTAssertNil(relaunched.generation(for: "ended", token: Data(repeating: 0xcd, count: 32)))
        relaunched.acknowledgeEnd("ended")

        let acknowledged = LiveActivityRegistrationStore(defaults: defaults)
        XCTAssertEqual(acknowledged.pendingEnds, ["ended-before-token"])
        XCTAssertEqual(acknowledged.generation(for: "active", token: token), 1)
        XCTAssertTrue(acknowledged.knownActivityIDs.contains("active"))
    }

    func testStoreReusesExistingPushInstallationIdentity() throws {
        let suite = "LiveActivityRegistrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installationID = UUID()
        defaults.set(installationID.uuidString, forKey: "pushInstallationID")
        XCTAssertEqual(LiveActivityRegistrationStore(defaults: defaults).installationID, installationID)
    }

    private func makeRegistration(installationID: UUID, activityID: String = "activity-123", isRiding: Bool? = nil) -> LiveActivityRegistration {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let startedAt = TripDetailTimeZoneFixtures.date("2026-09-15T22:10:00Z")
        let attributes = TrainJourneyAttributes(
            activityKey: "test-key", tripID: trip.id.rawValue,
            boardingStationID: trip.stopTimes[1].station.id.rawValue,
            alightingStationID: trip.stopTimes[2].station.id.rawValue,
            serviceName: trip.product, originName: trip.stopTimes[1].station.displayName,
            destinationName: trip.stopTimes[2].station.displayName,
            startedAt: startedAt.timeIntervalSince1970, boardingStopSequence: 1, alightingStopSequence: 2, isRiding: isRiding
        )
        let zones = Dictionary(uniqueKeysWithValues: trip.stopTimes.map {
            ($0.station.id, "America/New_York")
        })
        let state = TrainLiveActivityProjection(
            trip: trip, referenceDate: startedAt,
            boardingStationID: trip.stopTimes[1].station.id,
            alightingStationID: trip.stopTimes[2].station.id,
            stationTimeZones: zones, lastSuccessfulCheck: startedAt
        ).state
        return LiveActivityRegistration(
            installationID: installationID, activityID: activityID,
            token: Data(repeating: 0xab, count: 32), environment: "production",
            attributes: attributes, trip: trip, state: state, stationTimeZones: zones, tokenGeneration: 3
        )
    }
}

private actor RecordingLiveActivityBackend: LiveActivityBackendServing {
    private let suspendFirstUpload: Bool
    private let oldUploadFails: Bool
    private let registrationError: LiveActivityBackendClient.ClientError?
    private let endError: LiveActivityBackendClient.ClientError?
    private var registrations = 0
    private var ends: [String] = []
    private var endCalls = 0
    private var uploadContinuation: CheckedContinuation<Void, Never>?

    init(
        suspendFirstUpload: Bool = false, oldUploadFails: Bool = false,
        registrationError: LiveActivityBackendClient.ClientError? = nil,
        endError: LiveActivityBackendClient.ClientError? = nil
    ) {
        self.suspendFirstUpload = suspendFirstUpload
        self.oldUploadFails = oldUploadFails
        self.registrationError = registrationError
        self.endError = endError
    }

    func register(_ registration: LiveActivityRegistration) async throws {
        registrations += 1
        if let registrationError { throw registrationError }
        if registrations == 1, suspendFirstUpload {
            await withCheckedContinuation { uploadContinuation = $0 }
            if oldUploadFails { throw LiveActivityBackendClient.ClientError.rejected(401) }
        }
    }

    func end(activityID: String, installationID: UUID) throws {
        endCalls += 1
        if let endError { throw endError }
        ends.append(activityID)
    }
    func endAttempts() -> Int { endCalls }
    func endedIDs() -> [String] { ends }
    func registrationCount() -> Int { registrations }
    func releaseUpload() {
        uploadContinuation?.resume()
        uploadContinuation = nil
    }
}
