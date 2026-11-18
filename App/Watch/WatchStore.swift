import Foundation
import Observation
import TrainTrackerCore
import WatchConnectivity
import WatchKit

/// What the watch knows: the last payload the iPhone sent, and any wake request it has made
/// that the phone has not answered yet. The phone owns the trains and the alert; this only
/// mirrors them and asks.
@MainActor
@Observable
final class WatchStore: NSObject {
    /// How the wake switch reads for one train.
    enum WakeState: Equatable {
        case off
        /// Confirmed by the phone.
        case armed(lead: Int)
        /// Sent to the phone a moment ago. Never shown as armed.
        case asking(lead: Int?)
        /// The phone has not answered, or is out of reach. The request stays queued.
        case waiting(lead: Int?)
        /// The phone answered that it could not arm, and why.
        case problem(WatchWakeReply.Outcome)
    }

    /// How long "Asking iPhone…" lasts before the watch says it is still waiting.
    static let askingPatience: Duration = .seconds(12)

    private(set) var payload: WatchPayload?
    private var pending: [String: PendingWake] = [:]
    @ObservationIgnored private var unsent: [WatchWakeRequest] = []
    /// Set only by the DEBUG preview: there is no phone, and fixtures stand in for it.
    @ObservationIgnored private var isPreviewing = false
    /// A DEBUG preview asked to open on the wake switch, for screenshots.
    @ObservationIgnored private(set) var opensOnWake = false

    private struct PendingWake {
        let request: WatchWakeRequest
        var transfer: WCSessionUserInfoTransfer?
        var isStalled: Bool
    }

    /// The store the app runs with: the paired iPhone. A DEBUG build launched with
    /// `-WatchPreview` shows fixtures instead; none of that is compiled into Release.
    static func launch() -> WatchStore {
        let store = WatchStore()
        #if DEBUG
        if let preview = WatchPreview.fromLaunchArguments() {
            store.show(preview)
            return store
        }
        #endif
        store.connect()
        return store
    }

    private func connect() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if DEBUG
    private func show(_ preview: WatchPreview) {
        isPreviewing = true
        opensOnWake = preview.focusesWake
        payload = preview.payload
        if let held = preview.heldRequest {
            pending[held.request.tripID] = PendingWake(request: held.request, transfer: nil, isStalled: held.isStalled)
        }
    }
    #endif

    // MARK: Wake Me Before My Stop

    func wakeState(for tripID: String) -> WakeState {
        if let item = pending[tripID] {
            return item.isStalled ? .waiting(lead: item.request.leadMinutes) : .asking(lead: item.request.leadMinutes)
        }
        if let lead = payload?.wakeAlerts[tripID] { return .armed(lead: lead) }
        if let outcome = payload?.wakeReplies[tripID]?.outcome, outcome != .armed, outcome != .disarmed {
            return .problem(outcome)
        }
        return .off
    }

    /// Asks the phone to arm the train's wake alert with `lead` minutes, or to disarm it when
    /// nil. Queued by the system, so it still arrives if the phone is out of reach right now.
    func requestWake(for train: WidgetTripSnapshot.Train, lead: Int?) {
        // A replacement owns this train's queue. Otherwise canceling it could leave an
        // older, still-unsent arm behind to arrive when the phone reconnects.
        pending[train.id]?.transfer?.cancel()
        unsent.removeAll { $0.tripID == train.id }
        let request = WatchWakeRequest(tripID: train.id, stopID: train.alightingStationID, leadMinutes: lead, sentAt: .now)
        var item = PendingWake(request: request, transfer: nil, isStalled: false)
        if isPreviewing {
            #if DEBUG
            simulatePhone(answering: request)
            #endif
        } else if WCSession.isSupported(), WCSession.default.activationState == .activated {
            item.transfer = WCSession.default.transferUserInfo(request.userInfo)
            item.isStalled = !WCSession.default.isReachable
        } else {
            unsent.append(request)
            item.isStalled = true
        }
        pending[train.id] = item
        WKInterfaceDevice.current().play(.click)

        Task { [weak self] in
            try? await Task.sleep(for: Self.askingPatience)
            guard let self, self.pending[request.tripID]?.request.id == request.id else { return }
            self.pending[request.tripID]?.isStalled = true
        }
    }

    /// Takes back a request the phone has not answered. If the phone already has it, the
    /// phone's answer still arrives and the switch follows it.
    func cancelWakeRequest(for tripID: String) {
        guard let item = pending.removeValue(forKey: tripID) else { return }
        item.transfer?.cancel()
        unsent.removeAll { $0.id == item.request.id }
    }

    // MARK: From the phone

    private func apply(_ new: WatchPayload) {
        // At activation the system can replay an older context after a newer one.
        if let payload, new.generatedAt < payload.generatedAt { return }
        payload = new
        for (tripID, item) in pending {
            guard new.snapshot.trains.contains(where: { $0.id == tripID }) else {
                pending[tripID] = nil
                continue
            }
            // Only the phone's answer to this very request settles it. A payload that happens
            // to match what was asked (no alert, while a disarm waits) may be older than the ask.
            if let reply = new.answer(to: item.request) {
                pending[tripID] = nil
                let succeeded = reply.outcome == .armed || reply.outcome == .disarmed
                WKInterfaceDevice.current().play(succeeded ? .success : .failure)
            }
        }
    }

    private func sessionBecameActive(context: WatchPayload?) {
        if let context { apply(context) }
        for request in unsent {
            let transfer = WCSession.default.transferUserInfo(request.userInfo)
            if pending[request.tripID]?.request.id == request.id { pending[request.tripID]?.transfer = transfer }
        }
        unsent.removeAll()
    }

    #if DEBUG
    /// Under `-WatchPreview` there is no phone: answer as it would, after a beat.
    private func simulatePhone(answering request: WatchWakeRequest) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, var next = self.payload else { return }
            next.generatedAt = .now
            next.wakeAlerts[request.tripID] = request.leadMinutes
            next.wakeReplies[request.tripID] = WatchWakeReply(
                requestID: request.id, outcome: request.leadMinutes == nil ? .disarmed : .armed
            )
            self.apply(next)
        }
    }
    #endif
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        let context = WatchPayload(context: session.receivedApplicationContext)
        Task { @MainActor in self.sessionBecameActive(context: context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let payload = WatchPayload(context: applicationContext) else { return }
        Task { @MainActor in self.apply(payload) }
    }
}
