import SwiftUI
import TrainTrackerCore

/// The few live facts a passenger acts on. Haptics and VoiceOver speak only when one of these
/// changes between two confirmed checks, never when saved details load or a screen opens.
struct LiveChangeSignal: Equatable {
    var platform: String?
    var platformNoun = "Platform"
    var delayMinutes = 0
    var isCancelled = false
    /// False until a check succeeds this session; saved details never announce themselves.
    var isConfirmed = false

    init(platform: String? = nil, platformNoun: String = "Platform", delayMinutes: Int = 0,
         isCancelled: Bool = false, isConfirmed: Bool = false) {
        self.platform = platform
        self.platformNoun = platformNoun
        self.delayMinutes = delayMinutes
        self.isCancelled = isCancelled
        self.isConfirmed = isConfirmed
    }

    /// The boarding or next stop's reported assignment and the trip's status, as on the ticket.
    init(stop: StopTime?, status: TripPresentationStatus, isConfirmed: Bool) {
        self.init(
            platform: stop?.expectedPlatform?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            platformNoun: stop?.platformNoun ?? "Platform",
            delayMinutes: status.kind == .delayed ? status.delayMinutes : 0,
            isCancelled: status.kind == .cancelled,
            isConfirmed: isConfirmed
        )
    }

    enum Change: Equatable {
        case cancelled
        case platform(String)
        case later(minutes: Int)
    }

    /// The most important change from `old`, if both are confirmed. A delay counts once it grows
    /// by five minutes or more, matching when the app starts calling a train late.
    static func change(from old: LiveChangeSignal, to new: LiveChangeSignal) -> Change? {
        guard old.isConfirmed, new.isConfirmed else { return nil }
        if new.isCancelled, !old.isCancelled { return .cancelled }
        if let platform = new.platform, platform != old.platform { return .platform(platform) }
        if new.delayMinutes >= 5, new.delayMinutes - old.delayMinutes >= 5 { return .later(minutes: new.delayMinutes) }
        return nil
    }

    func announcement(for change: Change) -> String {
        switch change {
        case .cancelled: "Train canceled"
        case let .platform(value): "\(platformNoun) \(value)"
        case let .later(minutes): "Now \(minutes) minutes late"
        }
    }

    static func feedback(for change: Change) -> SensoryFeedback {
        switch change {
        case .cancelled: .error
        case .platform: .impact(weight: .heavy)
        case .later: .warning
        }
    }
}

extension View {
    func liveChangeFeedback(_ signal: LiveChangeSignal) -> some View {
        modifier(LiveChangeFeedbackModifier(signal: signal))
    }
}

/// The haptic follows the Haptics preference; the VoiceOver announcement always posts.
private struct LiveChangeFeedbackModifier: ViewModifier {
    @AppStorage(TrainTrackerPreference.liveHaptics) private var liveHaptics = true
    let signal: LiveChangeSignal

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: signal) { old, new in
                guard liveHaptics else { return nil }
                return LiveChangeSignal.change(from: old, to: new).map(LiveChangeSignal.feedback(for:))
            }
            .onChange(of: signal) { old, new in
                guard let change = LiveChangeSignal.change(from: old, to: new) else { return }
                AccessibilityNotification.Announcement(new.announcement(for: change)).post()
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
