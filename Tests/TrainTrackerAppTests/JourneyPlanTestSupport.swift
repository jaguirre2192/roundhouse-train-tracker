import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class RecordingPushCoordinator: PushCoordinating {
    var deliveryWarningHandler: ((PushDeliveryWarningEvent) -> Void)?
    private(set) var watchedTripIDs: [RailIdentifier] = []
    private(set) var unwatchedTripIDs: [RailIdentifier] = []
    var onWatch: ((TrainTrip) -> Void)?

    func connect() {}

    func watch(_ trip: TrainTrip) {
        watchedTripIDs.append(trip.id)
        onWatch?(trip)
    }

    func unwatch(_ trip: TrainTrip) {
        unwatchedTripIDs.append(trip.id)
    }

    func reportDeliveryWarning(
        _ hasWarning: Bool,
        affectedTripIDs: Set<RailIdentifier> = [],
        reason: PushDeliveryWarningReason = .backendSynchronizationFailed
    ) {
        deliveryWarningHandler?(PushDeliveryWarningEvent(
            reason: hasWarning ? reason : nil,
            affectedTripIDs: affectedTripIDs
        ))
    }
}

@MainActor
final class RecordingJourneyPlanArchive: JourneyPlanArchiving {
    enum Failure: Error { case save }

    var storedPlans: [TrackedJourneyPlan]
    var storedTrackingAttempts: [JourneyPlanTrackingAttempt] = []
    var shouldFailSave = false
    var onSave: (([TrackedJourneyPlan]) -> Void)?

    init(plans: [TrackedJourneyPlan] = []) {
        storedPlans = plans
    }

    func load() throws -> [TrackedJourneyPlan] { storedPlans }

    func save(_ plans: [TrackedJourneyPlan]) throws {
        onSave?(plans)
        if shouldFailSave { throw Failure.save }
        storedPlans = plans
    }

    func loadTrackingAttempts() throws -> [JourneyPlanTrackingAttempt] {
        storedTrackingAttempts
    }

    func saveTrackingAttempts(_ attempts: [JourneyPlanTrackingAttempt]) throws {
        storedTrackingAttempts = attempts
    }
}

actor TestPushBackend: PushBackendServing {
    nonisolated let isConfigured = true
    private var registrationFailure = false
    private var subscriptionFailure = false
    private var unsubscriptionFailure = false
    private var platforms: [PushBackendClient.Platform] = []
    private var registrationTokens: [Data] = []
    private var activeTripIDs: Set<RailIdentifier> = []
    private var unsubscribedTripIDs: [RailIdentifier] = []

    func setFailures(registration: Bool, subscription: Bool) {
        registrationFailure = registration
        subscriptionFailure = subscription
    }

    func setUnsubscriptionFailure(_ shouldFail: Bool) {
        unsubscriptionFailure = shouldFail
    }

    func registerDevice(
        token: Data,
        installationID: UUID,
        environment: PushBackendClient.Environment,
        platform: PushBackendClient.Platform
    ) async throws {
        if registrationFailure { throw PushBackendClient.ClientError.rejected(503) }
        platforms.append(platform)
        registrationTokens.append(token)
    }

    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws {
        if subscriptionFailure { throw PushBackendClient.ClientError.rejected(503) }
        activeTripIDs.insert(request.trip.id)
    }

    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {
        if unsubscriptionFailure { throw PushBackendClient.ClientError.rejected(503) }
        activeTripIDs.remove(tripID)
        unsubscribedTripIDs.append(tripID)
    }

    func registeredPlatforms() -> [PushBackendClient.Platform] { platforms }
    func registeredTokens() -> [Data] { registrationTokens }
    func unsubscribedIDs() -> [RailIdentifier] { unsubscribedTripIDs }
    func isActive(_ id: RailIdentifier) -> Bool { activeTripIDs.contains(id) }
}

actor SuspendingPushBackend: PushBackendServing {
    nonisolated let isConfigured = true
    private var startedTripIDs: [RailIdentifier] = []
    private var completedTripIDs: [RailIdentifier] = []
    private var activeTripIDs: Set<RailIdentifier> = []
    private var unsubscribedTripIDs: [RailIdentifier] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [RailIdentifier: CheckedContinuation<Void, Never>] = [:]

    func registerDevice(
        token: Data,
        installationID: UUID,
        environment: PushBackendClient.Environment,
        platform: PushBackendClient.Platform
    ) async throws {}

    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws {
        let id = request.trip.id
        startedTripIDs.append(id)
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuations[id] = continuation
        }
        activeTripIDs.insert(id)
        completedTripIDs.append(id)
    }

    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {
        activeTripIDs.remove(tripID)
        unsubscribedTripIDs.append(tripID)
    }

    func waitUntilStarted(count: Int) async {
        while startedTripIDs.count < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func release(_ id: RailIdentifier) {
        releaseContinuations.removeValue(forKey: id)?.resume()
    }

    func startedIDs() -> [RailIdentifier] { startedTripIDs }
    func completedIDs() -> [RailIdentifier] { completedTripIDs }
    func unsubscribedIDs() -> [RailIdentifier] { unsubscribedTripIDs }
    func isActive(_ id: RailIdentifier) -> Bool { activeTripIDs.contains(id) }
}

actor SuspendingDeviceRegistrationBackend: PushBackendServing {
    nonisolated let isConfigured = true
    private var startedTokens: [Data] = []
    private var completedTokens: [Data] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [Data: CheckedContinuation<Void, Never>] = [:]

    func registerDevice(
        token: Data,
        installationID: UUID,
        environment: PushBackendClient.Environment,
        platform: PushBackendClient.Platform
    ) async throws {
        startedTokens.append(token)
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuations[token] = continuation
        }
        completedTokens.append(token)
    }

    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws {}
    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws {}

    func waitUntilStarted(count: Int) async {
        while startedTokens.count < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func release(_ token: Data) {
        releaseContinuations.removeValue(forKey: token)?.resume()
    }

    func completedRegistrationTokens() -> [Data] { completedTokens }
}

@MainActor
final class TestPushAuthorizer: PushNotificationAuthorizing {
    private let status: PushAuthorizationStatus
    private let requestedResult: Bool

    init(status: PushAuthorizationStatus, requestedResult: Bool = true) {
        self.status = status
        self.requestedResult = requestedResult
    }

    func authorizationStatus() async -> PushAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { requestedResult }
}

enum JourneyPlanTestFixtures {
    struct TestFailure: Error {}

    @MainActor
    struct TripLibraryContext {
        let library: TripLibrary
        let archive: TripArchive
        let push: RecordingPushCoordinator
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() { defaults.removePersistentDomain(forName: suiteName) }
    }

    @MainActor
    static func makeTripLibrary(
        trips: [TrainTrip] = [],
        pushCoordinator: (any PushCoordinating)? = nil,
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_721_814_000)
        }
    ) throws -> TripLibraryContext {
        let suiteName = "JourneyPlanLibraryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let archive = TripArchive(defaults: defaults)
        let recording = RecordingPushCoordinator()
        let library = TripLibrary(
            trips: trips,
            pushCoordinator: pushCoordinator ?? recording,
            archive: archive,
            automaticRefreshEnabled: false,
            now: now
        )
        return TripLibraryContext(
            library: library,
            archive: archive,
            push: recording,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    @MainActor
    static func makeDraft(
        id: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        includesReturn: Bool = false
    ) -> JourneyPlanDraft {
        JourneyPlanDraft(
            id: id,
            origin: makePlace(id: "eu:transitous:paris", name: "Paris"),
            destination: makePlace(id: "eu:transitous:amsterdam", name: "Amsterdam"),
            outbound: makeOption(
                id: "outbound",
                fingerprint: "outbound-fingerprint",
                start: Date(timeIntervalSince1970: 1_721_890_000),
                end: Date(timeIntervalSince1970: 1_721_930_000)
            ),
            returnOption: includesReturn ? makeOption(
                id: "return",
                fingerprint: "return-fingerprint",
                start: Date(timeIntervalSince1970: 1_722_150_000),
                end: Date(timeIntervalSince1970: 1_722_190_000)
            ) : nil
        )
    }

    @MainActor
    static func makeResolution(
        outboundTrips: [TrainTrip],
        outboundFailureCount: Int = 0,
        returnTrips: [TrainTrip]? = nil
    ) -> JourneyPlanResolution {
        let tripSegments = outboundTrips.enumerated().map { index, trip in
            JourneyPlanResolution.Segment(segmentID: "segment-\(index)", trip: trip, failure: nil)
        }
        let failures = (0..<outboundFailureCount).map { index in
            JourneyPlanResolution.Segment(
                segmentID: "failure-\(index)",
                trip: nil,
                failure: JourneyPlanResolution.Failure(code: .notFound, message: "Unavailable")
            )
        }
        var directions = [JourneyPlanResolution.Direction(
            fingerprint: "outbound-fingerprint",
            originStationID: RailIdentifier(rawValue: "eu:transitous:paris-nord"),
            destinationStationID: RailIdentifier(rawValue: "eu:transitous:amsterdam-centraal"),
            departure: Date(timeIntervalSince1970: 1_721_890_000),
            arrival: Date(timeIntervalSince1970: 1_721_930_000),
            segments: tripSegments + failures
        )]
        if let returnTrips {
            directions.append(JourneyPlanResolution.Direction(
                fingerprint: "return-fingerprint",
                originStationID: RailIdentifier(rawValue: "eu:transitous:amsterdam-centraal"),
                destinationStationID: RailIdentifier(rawValue: "eu:transitous:paris-nord"),
                departure: Date(timeIntervalSince1970: 1_722_150_000),
                arrival: Date(timeIntervalSince1970: 1_722_190_000),
                segments: returnTrips.enumerated().map { index, trip in
                    JourneyPlanResolution.Segment(segmentID: "return-\(index)", trip: trip, failure: nil)
                }
            ))
        }
        return JourneyPlanResolution(directions: directions)
    }

    @MainActor
    static func makeTrips() -> [TrainTrip] {
        PreviewTrips.make(referenceDate: Date(timeIntervalSince1970: 1_721_814_000))
    }

    @MainActor
    static func replacingCoordinate(in trip: TrainTrip, latitude: Double) -> TrainTrip {
        let stops = trip.stopTimes.map { stop in
            StopTime(
                station: Station(
                    id: stop.station.id,
                    names: stop.station.names,
                    codes: stop.station.codes,
                    location: GeoCoordinate(latitude: latitude, longitude: stop.station.location.longitude),
                    countryCode: stop.station.countryCode,
                    operatorHints: stop.station.operatorHints
                ),
                sequence: stop.sequence,
                scheduledArrival: stop.scheduledArrival,
                scheduledDeparture: stop.scheduledDeparture,
                expectedArrival: stop.expectedArrival,
                expectedDeparture: stop.expectedDeparture,
                plannedPlatform: stop.plannedPlatform,
                expectedPlatform: stop.expectedPlatform,
                isCancelled: stop.isCancelled,
                isPassed: stop.isPassed
            )
        }
        return TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: stops,
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: trip.capabilities
        )
    }

    @MainActor
    static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    @MainActor
    private static func makePlace(id: String, name: String) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: id),
            kind: .city,
            displayName: name,
            context: "All stations",
            countryCode: "FR",
            timeZoneIdentifier: "Europe/Paris",
            location: GeoCoordinate(latitude: 48.8566, longitude: 2.3522),
            eligibleModes: ["highSpeedRail"],
            attributions: ["Transitous"]
        )
    }

    @MainActor
    private static func makeOption(id: String, fingerprint: String, start: Date, end: Date) -> JourneyOption {
        JourneyOption(
            id: id,
            fingerprint: fingerprint,
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            transferCount: 0,
            segments: [],
            badges: [.direct],
            trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 1),
            realtimeFreshness: nil,
            attributions: ["Transitous"],
            trackingToken: "tracking-token"
        )
    }
}
