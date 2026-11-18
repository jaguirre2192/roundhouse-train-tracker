import Foundation
import OSLog
import TrainTrackerCore
import UserNotifications
import UIKit

protocol PushBackendServing: Sendable {
    var isConfigured: Bool { get }

    func registerDevice(
        token: Data,
        installationID: UUID,
        environment: PushBackendClient.Environment,
        platform: PushBackendClient.Platform
    ) async throws
    func subscribe(_ request: PushBackendClient.TripWatchRequest) async throws
    func unsubscribe(installationID: UUID, tripID: RailIdentifier) async throws
}

extension PushBackendClient: PushBackendServing {}

enum PushAuthorizationStatus: Sendable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
protocol PushNotificationAuthorizing {
    func authorizationStatus() async -> PushAuthorizationStatus
    func requestAuthorization() async throws -> Bool
}

@MainActor
private struct SystemPushNotificationAuthorizer: PushNotificationAuthorizing {
    let notificationCenter: UNUserNotificationCenter

    func authorizationStatus() async -> PushAuthorizationStatus {
        switch await notificationCenter.notificationSettings().authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .denied:
            .denied
        @unknown default:
            .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

@MainActor
protocol PushCoordinating: AnyObject {
    var deliveryWarningHandler: ((PushDeliveryWarningEvent) -> Void)? { get set }
    func connect()
    func watch(_ trip: TrainTrip)
    func unwatch(_ trip: TrainTrip)
    func retryDelivery()
}

extension PushCoordinating {
    func retryDelivery() { connect() }
}

struct PushDeliveryWarningEvent: Equatable, Sendable {
    let reason: PushDeliveryWarningReason?
    let affectedTripIDs: Set<RailIdentifier>
    /// Trains the alert service refused individually. These never block other trains and are
    /// reported even when `reason` is nil.
    var tripAlertRejections: [RailIdentifier: PushTripAlertRejection] = [:]

    var hasWarning: Bool { reason != nil }
}

enum PushDeliveryWarningReason: Equatable, Sendable {
    case authorizationDenied
    case authorizationFailed
    case remoteRegistrationFailed
    case backendSynchronizationFailed
    case backendSetupRejected
    case backendRateLimited
}

/// Live Activities share the push installation identity and its device credential.
@MainActor
protocol LiveActivityInstallationHandling: AnyObject {
    /// Called when the Live Activity service rejects this installation's credential.
    var installationRejectionHandler: (() -> Void)? { get set }
    /// Moves running Live Activities to the replacement installation now in `pushInstallationID`.
    func installationWasReplaced()
}

@MainActor
final class PushRegistrationCoordinator: PushCoordinating {
    var deliveryWarningHandler: ((PushDeliveryWarningEvent) -> Void)?
    /// Trains the alert service refused on their own, such as when the watch limit is reached.
    private(set) var tripAlertRejections: [RailIdentifier: PushTripAlertRejection] = [:]

    private let backend: any PushBackendServing
    private let authorizer: any PushNotificationAuthorizing
    private let registerForRemoteNotifications: () -> Void
    private var installationID: UUID
    private let defaults: UserDefaults
    private let retryDelay: Duration
    private let environment: PushBackendClient.Environment
    private let selectedSegment: @MainActor (RailIdentifier) throws -> JourneyPlanSegment?
    private let liveActivitiesOverride: (any LiveActivityInstallationHandling)?
    private let logger = Logger(subsystem: "com.jorgeaguirre.TrainTracker", category: "push")
    private var pendingTrips: [RailIdentifier: TrainTrip] = [:]
    private var pendingUnwatchTripIDs: Set<RailIdentifier> = []
    /// Every train currently watched this launch, so a replacement installation can re-enroll them.
    private var watchedTrips: [RailIdentifier: TrainTrip] = [:]
    /// Watches the service accepted for this installation this launch; repeats are skipped.
    private var confirmedWatches: [RailIdentifier: String] = [:]
    /// The stops last sent per train. The service keys watches by stops, so a changed leg must
    /// retire the old watch first. Missing entries are assumed to cover the whole train.
    private var alertRanges: [String: String] = [:]
    private var deviceToken: Data?
    private var deviceTokenGeneration = 0
    private var needsDeviceRegistration = false
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var retryNotBefore: Date?
    private var deviceRegistrationWasUnauthorized = false
    private var didReplaceRejectedInstallation = false

    init(
        backend: any PushBackendServing = PushBackendClient(),
        notificationCenter: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        authorizer: (any PushNotificationAuthorizing)? = nil,
        registerForRemoteNotifications: (() -> Void)? = nil,
        retryDelay: Duration = .seconds(15),
        environment: PushBackendClient.Environment = .configured,
        selectedSegment: (@MainActor (RailIdentifier) -> JourneyPlanSegment?)? = nil,
        liveActivities: (any LiveActivityInstallationHandling)? = nil,
        planArchive: JourneyPlanArchive? = nil
    ) {
        self.backend = backend
        self.defaults = defaults
        self.retryDelay = retryDelay
        self.environment = environment
        // Saved journeys are read at send time so alerts follow the rider's current leg.
        let savedPlans = planArchive ?? (defaults === UserDefaults.standard ? JourneyPlanArchive.standard : JourneyPlanArchive(defaults: defaults))
        if let selectedSegment { self.selectedSegment = selectedSegment }
        else {
            self.selectedSegment = { tripID in
                let plans = try savedPlans.load()
                return JourneyTripContext.selectedSegment(for: tripID, plans: plans)
            }
        }
        liveActivitiesOverride = liveActivities
        self.authorizer = authorizer ?? SystemPushNotificationAuthorizer(
            notificationCenter: notificationCenter
        )
        self.registerForRemoteNotifications = registerForRemoteNotifications
            ?? Self.registerForRemoteNotifications
        if let value = defaults.string(forKey: "pushInstallationID"), let saved = UUID(uuidString: value) {
            installationID = saved
        } else {
            let value = UUID()
            installationID = value
            defaults.set(value.uuidString, forKey: "pushInstallationID")
        }
        pendingUnwatchTripIDs = Set(
            (defaults.stringArray(forKey: Self.pendingUnwatchDefaultsKey) ?? [])
                .map(RailIdentifier.init(rawValue:))
        )
        alertRanges = defaults.dictionary(forKey: Self.alertRangesDefaultsKey) as? [String: String] ?? [:]
    }

    private var liveActivities: any LiveActivityInstallationHandling {
        liveActivitiesOverride ?? TrainLiveActivityManager.shared
    }

    func connect() {
        PushRegistrationBridge.shared.connect(self)
        liveActivities.installationRejectionHandler = { [weak self] in
            self?.liveActivityInstallationWasRejected()
        }
        if !pendingUnwatchTripIDs.isEmpty {
            Task {
                await flush()
                if !pendingUnwatchTripIDs.isEmpty {
                    requestAuthorizationAndRegistration()
                }
            }
        }
    }

    func watch(_ trip: TrainTrip) {
        guard backend.isConfigured else { return }
        watchedTrips[trip.id] = trip
        pendingTrips[trip.id] = trip
        requestAuthorizationAndRegistration()
    }

    func unwatch(_ trip: TrainTrip) {
        pendingTrips[trip.id] = nil
        watchedTrips[trip.id] = nil
        tripAlertRejections[trip.id] = nil
        guard backend.isConfigured else { return }
        pendingUnwatchTripIDs.insert(trip.id)
        persistPendingUnwatchTripIDs()
        Task { await flush() }
    }

    func receivedDeviceToken(_ token: Data) {
        guard token != deviceToken else {
            Task { await flush() }
            return
        }
        deviceToken = token
        deviceTokenGeneration &+= 1
        needsDeviceRegistration = true
        Task { await flush() }
    }

    /// An explicit retry repairs device enrollment once and also retries removals with no trains.
    func retryDelivery() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        if deviceRegistrationWasUnauthorized, !didReplaceRejectedInstallation {
            replaceRejectedInstallation()
        }
        if deviceToken != nil { needsDeviceRegistration = true }
        if pendingTrips.isEmpty, deviceToken != nil {
            // Removing old watches must still work if notification permission was later denied.
            Task { await flush() }
        } else {
            requestAuthorizationAndRegistration()
        }
    }

    /// The Live Activity service rejected this installation's credential. That needs the same
    /// one-time replacement as a rejected device enrollment, and works without an APNs token.
    func liveActivityInstallationWasRejected() {
        guard !didReplaceRejectedInstallation else { return }
        replaceRejectedInstallation()
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        Task { await flush() }
    }

    /// A restored installation can outlive its device-only Keychain credential. Enroll this phone
    /// as a new installation once per launch; never claim the original phone's state.
    private func replaceRejectedInstallation() {
        installationID = UUID()
        defaults.set(installationID.uuidString, forKey: "pushInstallationID")
        didReplaceRejectedInstallation = true
        deviceRegistrationWasUnauthorized = false
        // These removals belong to the inaccessible installation, not the new one.
        pendingUnwatchTripIDs.removeAll()
        persistPendingUnwatchTripIDs()
        // The new installation watches nothing yet, so every saved train is enrolled again.
        confirmedWatches.removeAll()
        alertRanges.removeAll()
        persistAlertRanges()
        tripAlertRejections.removeAll()
        pendingTrips.merge(watchedTrips) { pending, _ in pending }
        if deviceToken != nil { needsDeviceRegistration = true }
        liveActivities.installationWasReplaced()
    }

    func registrationFailed(_ error: Error) {
        logger.error("Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
        reportDeliveryWarning(.remoteRegistrationFailed)
    }

    private func authorizeAndRegister() async {
        do {
            let authorized: Bool
            switch await authorizer.authorizationStatus() {
            case .notDetermined:
                authorized = try await authorizer.requestAuthorization()
            case .authorized:
                authorized = true
            case .denied:
                authorized = false
            }
            guard authorized else {
                reportDeliveryWarning(.authorizationDenied)
                return
            }

            if deviceToken == nil { registerForRemoteNotifications() }

            if deviceToken != nil { await flush() }
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            reportDeliveryWarning(.authorizationFailed)
        }
    }

    private func requestAuthorizationAndRegistration() {
        guard authorizationTask == nil else { return }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            await self.authorizeAndRegister()
            self.authorizationTask = nil
        }
    }

    private func flush() async {
        guard !isFlushing else { return }
        if let retryNotBefore, retryNotBefore > .now {
            scheduleRetry(after: .seconds(retryNotBefore.timeIntervalSinceNow))
            return
        }
        guard needsDeviceRegistration
                || !pendingTrips.isEmpty
                || !pendingUnwatchTripIDs.isEmpty
        else { return }
        isFlushing = true
        defer { isFlushing = false }

        do {
            while true {
                if needsDeviceRegistration, let deviceToken {
                    let generation = deviceTokenGeneration
                    let registeringInstallationID = installationID
                    do {
                        try await backend.registerDevice(
                            token: deviceToken,
                            installationID: registeringInstallationID,
                            environment: environment,
                            platform: Self.platform
                        )
                        guard registeringInstallationID == installationID else { continue }
                        deviceRegistrationWasUnauthorized = false
                    } catch {
                        // A manual retry may replace the installation while enrollment is awaiting.
                        guard registeringInstallationID == installationID else { continue }
                        if case PushBackendClient.ClientError.rejected(401) = error {
                            deviceRegistrationWasUnauthorized = true
                        } else {
                            deviceRegistrationWasUnauthorized = false
                        }
                        throw error
                    }
                    if generation == deviceTokenGeneration, self.deviceToken == deviceToken {
                        needsDeviceRegistration = false
                    }
                    continue
                }

                if let id = pendingUnwatchTripIDs.first {
                    try await backend.unsubscribe(installationID: installationID, tripID: id)
                    pendingUnwatchTripIDs.remove(id)
                    persistPendingUnwatchTripIDs()
                    confirmedWatches[id] = nil
                    setAlertRange(nil, for: id)
                    requeueTripsRejectedForQuota()
                    continue
                }

                guard deviceToken != nil, !needsDeviceRegistration,
                      let (id, trip) = pendingTrips.first
                else { break }
                let watchingInstallationID = installationID
                guard let range = try alertRange(for: trip) else {
                    // Without two known stops the service cannot watch this train.
                    pendingTrips[id] = nil
                    tripAlertRejections[id] = .invalidTrip
                    continue
                }
                let signature = Self.watchSignature(installationID: installationID, trip: trip, range: range)
                if confirmedWatches[id] == signature, !pendingUnwatchTripIDs.contains(id) {
                    pendingTrips[id] = nil
                    continue
                }
                let wholeTrainKey = TripAlertRange(trip: trip, segment: nil)?.key
                if (alertRanges[id.rawValue] ?? wholeTrainKey) != range.key {
                    // Watches are keyed by stops; retire the previous leg before watching the new one.
                    try await backend.unsubscribe(installationID: installationID, tripID: id)
                    confirmedWatches[id] = nil
                    setAlertRange(nil, for: id)
                    guard watchingInstallationID == installationID else { continue }
                }
                do {
                    try await backend.subscribe(.init(installationID: installationID, trip: trip, range: range))
                } catch let PushBackendClient.ClientError.tripRejected(rejection) {
                    // One refused train must not hold back the rest of the queue.
                    guard watchingInstallationID == installationID else { continue }
                    if pendingTrips[id] == trip {
                        pendingTrips[id] = nil
                        tripAlertRejections[id] = rejection
                    }
                    continue
                }
                // A replacement installation re-queued this train; enroll it under the new identity.
                guard watchingInstallationID == installationID else { continue }
                setAlertRange(range.key, for: id)
                tripAlertRejections[id] = nil
                if pendingUnwatchTripIDs.contains(id) {
                    continue
                } else if pendingTrips[id] == trip {
                    pendingTrips[id] = nil
                    confirmedWatches[id] = signature
                } else {
                    pendingUnwatchTripIDs.insert(id)
                    persistPendingUnwatchTripIDs()
                }
            }
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
            retryNotBefore = nil
            if pendingTrips.isEmpty,
               pendingUnwatchTripIDs.isEmpty,
               !needsDeviceRegistration {
                reportDeliveryWarning(nil)
            }
        } catch {
            logger.error("Push watcher synchronization failed: \(error.localizedDescription, privacy: .public)")
            if case let PushBackendClient.ClientError.rateLimited(delay) = error {
                retryNotBefore = .now.addingTimeInterval(delay)
                reportDeliveryWarning(.backendRateLimited)
                scheduleRetry(after: .seconds(delay))
                return
            }
            if case let PushBackendClient.ClientError.rejected(status) = error,
               (400..<500).contains(status), status != 408 {
                // A rejected setup needs an explicit retry; repeating it cannot repair ownership.
                retryTask?.cancel()
                retryTask = nil
                reportDeliveryWarning(.backendSetupRejected)
                return
            }
            reportDeliveryWarning(.backendSynchronizationFailed)
            scheduleRetry()
        }
    }

    private func reportDeliveryWarning(_ reason: PushDeliveryWarningReason?) {
        deliveryWarningHandler?(PushDeliveryWarningEvent(
            reason: reason,
            affectedTripIDs: reason != nil
                ? Set(pendingTrips.keys).union(pendingUnwatchTripIDs)
                : [],
            tripAlertRejections: tripAlertRejections
        ))
    }

    private func alertRange(for trip: TrainTrip) throws -> TripAlertRange? {
        TripAlertRange(trip: trip, segment: try selectedSegment(trip.id))
    }

    /// Removing any watch can free capacity, so trains refused for the limit get another chance.
    private func requeueTripsRejectedForQuota() {
        for (id, rejection) in tripAlertRejections where rejection == .quotaExceeded {
            guard let trip = watchedTrips[id] else { continue }
            tripAlertRejections[id] = nil
            pendingTrips[id] = pendingTrips[id] ?? trip
        }
    }

    private func setAlertRange(_ key: String?, for id: RailIdentifier) {
        guard alertRanges[id.rawValue] != key else { return }
        alertRanges[id.rawValue] = key
        persistAlertRanges()
    }

    private func persistAlertRanges() {
        if alertRanges.isEmpty {
            defaults.removeObject(forKey: Self.alertRangesDefaultsKey)
        } else {
            defaults.set(alertRanges, forKey: Self.alertRangesDefaultsKey)
        }
    }

    private static func watchSignature(installationID: UUID, trip: TrainTrip, range: TripAlertRange) -> String {
        [
            installationID.uuidString, trip.source, trip.id.nativeID ?? trip.id.rawValue,
            "\(trip.serviceDate.timeIntervalSince1970)", range.key,
        ].joined(separator: "|")
    }

    private func scheduleRetry(after delay: Duration? = nil) {
        guard needsDeviceRegistration
                || !pendingTrips.isEmpty
                || !pendingUnwatchTripIDs.isEmpty
        else { return }
        retryTask?.cancel()
        let retryDelay = delay ?? self.retryDelay * (1 << min(retryAttempt, 4))
        retryAttempt = min(retryAttempt + 1, 4)
        retryTask = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func persistPendingUnwatchTripIDs() {
        let values = pendingUnwatchTripIDs.map(\.rawValue).sorted()
        if values.isEmpty {
            defaults.removeObject(forKey: Self.pendingUnwatchDefaultsKey)
        } else {
            defaults.set(values, forKey: Self.pendingUnwatchDefaultsKey)
        }
    }

    private static var platform: PushBackendClient.Platform {
        .ios
    }

    private static let pendingUnwatchDefaultsKey = "pushPendingUnwatchTripIDs"
    private static let alertRangesDefaultsKey = "pushAlertRanges.v1"

    private static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
final class PushRegistrationBridge {
    static let shared = PushRegistrationBridge()

    private weak var coordinator: PushRegistrationCoordinator?
    private var pendingToken: Data?
    private var pendingError: (any Error)?

    func connect(_ coordinator: PushRegistrationCoordinator) {
        self.coordinator = coordinator
        if let pendingToken {
            coordinator.receivedDeviceToken(pendingToken)
            self.pendingToken = nil
        } else if let pendingError {
            coordinator.registrationFailed(pendingError)
        }
        pendingError = nil
    }

    func receive(_ token: Data) {
        if let coordinator {
            coordinator.receivedDeviceToken(token)
        } else {
            pendingToken = token
            pendingError = nil
        }
    }

    /// APNs can fail before the app connects a coordinator; keep the failure so it is reported.
    func fail(_ error: Error) {
        if let coordinator {
            coordinator.registrationFailed(error)
        } else {
            pendingError = error
        }
    }
}
