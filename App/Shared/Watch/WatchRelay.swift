import Foundation
import Observation
import TrainTrackerCore
import WatchConnectivity

/// The iPhone's side of the Apple Watch app.
///
/// After each snapshot write it sends the watch the rider's next trains and which of them have
/// a wake alert armed, as the application context (only the latest matters, and the system
/// delivers it when the watch is next in reach). When the watch asks to arm or disarm
/// "Wake Me Before My Stop", it does so here, where the alert lives, and sends back what
/// actually happened so the watch never shows an alert the phone does not hold.
@MainActor
final class WatchRelay: NSObject {
    static let shared = WatchRelay()

    /// How long the phone may take to arm before the watch is told to finish on the phone.
    /// Arming can wait on a permission prompt, which iOS only shows while the app is open.
    private static let armPatience: Duration = .seconds(20)

    private weak var library: TripLibrary?
    private var lastSnapshot: WidgetTripSnapshot?
    private var replies: [String: WatchWakeReply] = [:]
    private var lastSent: WatchPayload?
    private var requestQueue: Task<Void, Never>?
    /// The newest request the watch has made for each train. An answer to an older one, or a
    /// late result from one, is never sent: the latest command wins.
    private var latestRequestID: [String: String] = [:]
    private var isObservingAlerts = false

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func connect(library: TripLibrary) {
        self.library = library
        // Fixture trains from a preview or a test never go to the rider's watch.
        guard !LaunchFixtures.isActive, let session else { return }
        if session.delegate == nil {
            session.delegate = self
            session.activate()
        }
        observeAlerts()
    }

    /// Called after every snapshot write. Sends only when the watch would show something new.
    func send(_ snapshot: WidgetTripSnapshot) {
        lastSnapshot = snapshot
        push()
    }

    private func push() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let snapshot = lastSnapshot else { return }
        let alerts = StopWakeAlerts.shared.alerts.mapValues(\.leadMinutes)
        // An answer only matters while its train is still on the watch.
        replies = replies.filter { reply in snapshot.trains.contains { $0.id == reply.key } }
        let payload = WatchPayload(generatedAt: .now, snapshot: snapshot, wakeAlerts: alerts, wakeReplies: replies)
        if let lastSent, lastSent.snapshot.trains == payload.snapshot.trains,
           lastSent.wakeAlerts == payload.wakeAlerts, lastSent.wakeReplies == payload.wakeReplies { return }
        guard let context = try? payload.context(), (try? session.updateApplicationContext(context)) != nil else { return }
        lastSent = payload
    }

    /// Sends again even when nothing changed, for a watch that has just become reachable.
    private func pushFresh() {
        lastSent = nil
        pushLatest()
    }

    private func pushLatest() {
        if lastSnapshot == nil {
            // Nothing written yet this launch (the phone was woken by the watch): write now,
            // which comes back through `send`.
            WidgetSnapshotPublisher.shared.writeNow()
        } else {
            push()
        }
    }

    /// Alerts also change on the phone itself: the rider's own switch, or a train passing the stop.
    private func observeAlerts() {
        guard !isObservingAlerts else { return }
        isObservingAlerts = true
        withObservationTracking {
            _ = StopWakeAlerts.shared.alerts
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObservingAlerts = false
                self.observeAlerts()
                self.push()
            }
        }
    }

    // MARK: Requests from the watch

    /// Requests are handled one at a time, in the order the watch sent them.
    private func enqueue(_ request: WatchWakeRequest) {
        latestRequestID[request.tripID] = request.id
        let previous = requestQueue
        requestQueue = Task { [weak self] in
            await previous?.value
            guard let self, let outcome = await self.outcome(of: request) else { return }
            self.answer(request, outcome)
        }
    }

    private func answer(_ request: WatchWakeRequest, _ outcome: WatchWakeReply.Outcome) {
        guard latestRequestID[request.tripID] == request.id else { return }
        replies[request.tripID] = WatchWakeReply(requestID: request.id, outcome: outcome)
        pushLatest()
    }

    /// Nil when a later request for the same train overtook this one; that one answers.
    private func outcome(of request: WatchWakeRequest) async -> WatchWakeReply.Outcome? {
        guard latestRequestID[request.tripID] == request.id else { return nil }
        guard let trip = library?.trips.first(where: { $0.id.rawValue == request.tripID }) else { return .tripNotFound }
        guard let requestedLead = request.leadMinutes else {
            StopWakeAlerts.shared.disarm(tripID: trip.id)
            return .disarmed
        }
        // The stop the rider gets off at, or the end of the line when the watch has no leg.
        guard let stopID = request.stopID ?? trip.stopTimes.last?.station.id.rawValue else { return .stopNotAhead }
        let lead = StopWakeAlerts.leadChoices.contains(requestedLead) ? requestedLead : StopWakeAlerts.defaultLead
        let product = trip.product.isEmpty ? trip.operatorName : trip.product

        let arming = Task { @MainActor in
            await StopWakeAlerts.shared.arm(trip: trip, stopID: stopID, productName: product, leadMinutes: lead)
        }
        let race = ArmRace()
        return await withCheckedContinuation { (continuation: CheckedContinuation<WatchWakeReply.Outcome?, Never>) in
            Task { @MainActor [weak self] in
                let outcome = Self.outcome(of: await arming.value)
                if race.finish() {
                    continuation.resume(returning: outcome)
                } else if let outcome {
                    // The rider answered the prompt on the phone after the watch was told to wait.
                    // `answer` drops it if the watch has asked for something else since.
                    self?.answer(request, outcome)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.armPatience)
                if race.finish() { continuation.resume(returning: .needsPhone) }
            }
        }
    }

    private static func outcome(of result: StopWakeAlerts.ArmResult) -> WatchWakeReply.Outcome? {
        switch result {
        case .armed: .armed
        case .notificationsDenied: .notificationsDenied
        case .stopNotAhead, .timetableElapsed: .stopNotAhead
        // Overtaken by a later command, which gives the answer.
        case .superseded: nil
        }
    }

    /// Whichever of arming and the patience timer finishes first answers the watch.
    @MainActor
    private final class ArmRace {
        private var isFinished = false

        func finish() -> Bool {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }
}

extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.pushFresh() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The rider switched to another watch: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The watch app was installed, or the watch was paired.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushFresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let request = WatchWakeRequest(userInfo: userInfo) else { return }
        Task { @MainActor in self.enqueue(request) }
    }
}
