import CoreLocation
import Foundation
import Observation
import TrainTrackerCore
import UserNotifications

/// What a wake alert needs from the train: which stop, when it is due, and how fast the train
/// comes into it. Worked out apart from scheduling so it can be tested.
struct StopWakePlan: Equatable {
    let stopName: String
    let coordinate: CLLocationCoordinate2D
    /// When the train is due at the stop, by the latest estimate.
    let arrival: Date
    /// How far out the "approaching" alert should sound, when location can be used.
    let radius: CLLocationDistance

    static let lastCallLead: TimeInterval = 2 * 60
    static let shortestRadius: CLLocationDistance = 1_500
    static let longestRadius: CLLocationDistance = 40_000

    static func == (lhs: StopWakePlan, rhs: StopWakePlan) -> Bool {
        lhs.stopName == rhs.stopName && lhs.arrival == rhs.arrival && lhs.radius == rhs.radius
            && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    /// Nil when the stop is not ahead of the train or has no time.
    init?(trip: TrainTrip, stopID: String, leadMinutes: Int) {
        guard !trip.isCancelled, let index = trip.stopTimes.firstIndex(where: { $0.station.id.rawValue == stopID }),
              index > 0 else { return nil }
        let stop = trip.stopTimes[index]
        // A reported arrival or passage makes a before-stop alert too late; a flag worked
        // out from the clock does not.
        guard !stop.hasConfirmedArrival(at: .now), !stop.isCancelled,
              let arrival = stop.expectedArrival ?? stop.scheduledArrival ?? stop.expectedDeparture ?? stop.scheduledDeparture
        else { return nil }
        let previous = trip.stopTimes[index - 1]
        let here = CLLocation(latitude: stop.station.location.latitude, longitude: stop.station.location.longitude)
        let before = CLLocation(latitude: previous.station.location.latitude, longitude: previous.station.location.longitude)
        let legDistance = here.distance(from: before)
        let legStart = previous.expectedDeparture ?? previous.scheduledDeparture ?? previous.expectedArrival ?? previous.scheduledArrival
        let legTime = legStart.map { arrival.timeIntervalSince($0) } ?? 0
        // The pace of the last leg in, held to what a train does.
        let speed = legTime > 60 ? min(max(legDistance / legTime, 12), 60) : 30
        let wanted = speed * Double(leadMinutes) * 60
        // Never so wide that the rider is inside it before leaving the stop before.
        let radius = min(max(wanted, Self.shortestRadius), Self.longestRadius, max(legDistance * 0.8, Self.shortestRadius))

        self.stopName = stop.station.displayName
        self.coordinate = here.coordinate
        self.arrival = arrival
        self.radius = radius
    }
}

/// "Wake me before my stop." One alert as the rider's station approaches and a last call two
/// minutes out, so a nap or a book doesn't carry them past it.
///
/// With location allowed, the first alert sounds when the phone itself comes within range of the
/// station, which stays right when the train runs late. The last call is always by the train's
/// estimated arrival, and so is the first when location is off.
@MainActor
@Observable
final class StopWakeAlerts {
    static let shared = StopWakeAlerts()

    struct Alert: Codable, Equatable {
        let tripID: String
        let stopID: String
        var stopName: String
        var leadMinutes: Int
        var usesLocation: Bool
        /// The arrival the alerts were last scheduled for.
        var scheduledArrival: Date
        /// Each scheduling command owns its identifiers, including after an app restart.
        /// Older saved alerts use the original identifiers until they are rescheduled.
        var requestGeneration: String? = nil
    }

    enum ArmResult: Equatable {
        case armed
        case notificationsDenied
        /// The train is reported at or past the stop.
        case stopNotAhead
        /// The stop's time has gone by with nothing reporting the train there, and without
        /// location there is nothing left to time an alert by.
        case timetableElapsed
        /// A later command for the same train (another arm, or a disarm) arrived while this
        /// one was waiting on a permission prompt. Nothing was stored or scheduled by it.
        case superseded
    }

    static let leadChoices = [5, 10, 15]
    static let defaultLead = 10

    private(set) var alerts: [String: Alert] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locationAuthorizer = WakeLocationAuthorizer()
    private static let storageKey = "stopWakeAlerts"
    /// Counts the commands given for each train. Arming waits on permission prompts, and a
    /// command that comes back from one acts only if it is still the latest for its train.
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// Asks for notifications, then location. Replaced in tests, where no prompt can be shown.
    @ObservationIgnored var requestPermissions: @MainActor () async -> (notifications: Bool, location: Bool) = { (false, false) }
    /// Hands a request to the system. Replaced in tests.
    @ObservationIgnored var addRequest: @MainActor (UNNotificationRequest) async -> Void = { _ in }
    @ObservationIgnored var removeRequests: @MainActor ([String]) -> Void = { _ in }
    @ObservationIgnored var pendingRequests: @MainActor () async -> [UNNotificationRequest] = { [] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let center = UNUserNotificationCenter.current()
        let authorizer = locationAuthorizer
        requestPermissions = {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return (false, false) }
            return (true, await authorizer.requestWhenInUse())
        }
        addRequest = { try? await center.add($0) }
        removeRequests = { center.removePendingNotificationRequests(withIdentifiers: $0) }
        pendingRequests = { await center.pendingNotificationRequests() }
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: Alert].self, from: data) {
            alerts = saved
        }
        Task { [weak self] in await self?.reconcilePendingRequests() }
    }

    func alert(for tripID: RailIdentifier) -> Alert? { alerts[tripID.rawValue] }

    /// Asks for what it needs, then schedules. Location is asked for but not required.
    func arm(trip: TrainTrip, stopID: String, productName: String, leadMinutes: Int) async -> ArmResult {
        guard let plan = StopWakePlan(trip: trip, stopID: stopID, leadMinutes: leadMinutes) else { return .stopNotAhead }
        let tripID = trip.id.rawValue
        let generation = nextGeneration(for: tripID)
        let permissions = await requestPermissions()
        // The rider may have switched it off, or asked again, while the prompt was up.
        guard isLatest(generation, for: tripID) else { return .superseded }
        guard permissions.notifications else { return .notificationsDenied }
        let usesLocation = permissions.location
        // A late train can still be met by location. By the clock alone the moment has gone.
        guard usesLocation || plan.arrival > .now else { return .timetableElapsed }
        let alert = Alert(
            tripID: trip.id.rawValue, stopID: stopID, stopName: plan.stopName,
            leadMinutes: leadMinutes, usesLocation: usesLocation, scheduledArrival: plan.arrival,
            requestGeneration: UUID().uuidString
        )
        if let previous = alerts[tripID] { removeRequests(Self.identifiers(for: previous)) }
        alerts[tripID] = alert
        save()
        await schedule(alert, plan: plan, productName: productName, generation: generation)
        return isLatest(generation, for: tripID) ? .armed : .superseded
    }

    private func nextGeneration(for tripID: String) -> Int {
        let next = (generations[tripID] ?? 0) + 1
        generations[tripID] = next
        return next
    }

    private func isLatest(_ generation: Int, for tripID: String) -> Bool {
        generations[tripID] == generation
    }

    func disarm(tripID: RailIdentifier) {
        // Any arm still waiting for this train is now out of date.
        _ = nextGeneration(for: tripID.rawValue)
        if let alert = alerts[tripID.rawValue] { removeRequests(Self.identifiers(for: alert)) }
        alerts[tripID.rawValue] = nil
        save()
        removeRequests(Self.legacyIdentifiers(for: tripID.rawValue))
        Task { [weak self] in await self?.reconcilePendingRequests() }
    }

    /// Keeps armed alerts in step with the trains: re-times them when an estimate moves by a
    /// minute or more, and drops them once the stop is behind the train or the train is gone.
    func sync(with trips: [TrainTrip]) {
        for (tripID, alert) in alerts {
            guard let trip = trips.first(where: { $0.id.rawValue == tripID }),
                  let plan = StopWakePlan(trip: trip, stopID: alert.stopID, leadMinutes: alert.leadMinutes) else {
                alerts[tripID] = nil
                _ = nextGeneration(for: tripID)
                removeRequests(Self.identifiers(for: alert))
                continue
            }
            guard abs(plan.arrival.timeIntervalSince(alert.scheduledArrival)) >= 60 else { continue }
            var updated = alert
            updated.scheduledArrival = plan.arrival
            updated.requestGeneration = UUID().uuidString
            removeRequests(Self.identifiers(for: alert))
            alerts[tripID] = updated
            let product = trip.product.isEmpty ? trip.operatorName : trip.product
            let generation = nextGeneration(for: tripID)
            Task { await schedule(updated, plan: plan, productName: product, generation: generation) }
        }
        save()
    }

    /// Each request is handed over only while this is still the train's latest command, and
    /// anything it added is taken back if a later command arrived meanwhile.
    private func schedule(_ alert: Alert, plan: StopWakePlan, productName: String, generation: Int) async {
        guard isLatest(generation, for: alert.tripID) else { return }
        let identifiers = Self.identifiers(for: alert)
        removeRequests(identifiers)
        defer {
            if !isLatest(generation, for: alert.tripID) {
                removeRequests(identifiers)
            }
        }
        let now = Date.now

        let approach = UNMutableNotificationContent()
        approach.title = "\(plan.stopName) is coming up"
        approach.body = "\(productName) is about \(alert.leadMinutes) minutes from your stop. Time to get your things together."
        approach.sound = .default
        approach.interruptionLevel = .timeSensitive
        approach.threadIdentifier = "wake.\(alert.tripID)"
        let approachTrigger: UNNotificationTrigger
        if alert.usesLocation {
            let region = CLCircularRegion(center: plan.coordinate, radius: plan.radius, identifier: identifiers[0])
            region.notifyOnEntry = true
            region.notifyOnExit = false
            approachTrigger = UNLocationNotificationTrigger(region: region, repeats: false)
        } else {
            let fire = plan.arrival.addingTimeInterval(-Double(alert.leadMinutes) * 60)
            approachTrigger = UNTimeIntervalNotificationTrigger(timeInterval: max(fire.timeIntervalSince(now), 2), repeats: false)
        }
        await addRequest(UNNotificationRequest(
            identifier: identifiers[0], content: approach, trigger: approachTrigger
        ))
        guard isLatest(generation, for: alert.tripID) else { return }

        // The last call is by the clock, so it still sounds in a tunnel or with location off.
        let lastCallDate = plan.arrival.addingTimeInterval(-StopWakePlan.lastCallLead)
        guard lastCallDate.timeIntervalSince(now) > 30 else { return }
        let lastCall = UNMutableNotificationContent()
        lastCall.title = "Arriving at \(plan.stopName)"
        lastCall.body = "\(productName) is due in about 2 minutes. This is your stop."
        lastCall.sound = .default
        lastCall.interruptionLevel = .timeSensitive
        lastCall.threadIdentifier = "wake.\(alert.tripID)"
        await addRequest(UNNotificationRequest(
            identifier: identifiers[1], content: lastCall,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: lastCallDate.timeIntervalSince(now), repeats: false)
        ))
    }

    private static func identifiers(for alert: Alert) -> [String] {
        guard let generation = alert.requestGeneration else { return legacyIdentifiers(for: alert.tripID) }
        return ["wake.\(alert.tripID).\(generation).approach", "wake.\(alert.tripID).\(generation).lastCall"]
    }

    private static func legacyIdentifiers(for tripID: String) -> [String] {
        ["wake.\(tripID).approach", "wake.\(tripID).lastCall"]
    }

    /// The query can suspend while a newer command is stored. Read current ownership after
    /// it returns, so restoring/disarming old requests cannot remove that newer command.
    func reconcilePendingRequests() async {
        let pending = await pendingRequests()
        let owned = Set(alerts.values.flatMap(Self.identifiers))
        let obsolete = pending.map(\.identifier).filter { $0.hasPrefix("wake.") && !owned.contains($0) }
        if !obsolete.isEmpty { removeRequests(obsolete) }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(alerts), forKey: Self.storageKey)
    }
}

/// Asks once for location while the app is in use and reports whether it may be used.
@MainActor
private final class WakeLocationAuthorizer: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestWhenInUse() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                waiting.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        @unknown default: return false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let allowed = manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
        waiting.forEach { $0.resume(returning: allowed) }
        waiting.removeAll()
    }
}
