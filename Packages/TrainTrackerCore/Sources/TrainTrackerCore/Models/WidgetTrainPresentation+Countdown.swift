import Foundation

/// The countdown and trust copy shared by the Home Screen widgets and the Apple Watch app.
/// Moved here from the widget extension so both read the same words.
public extension WidgetTrainPresentation {
    /// The app's one word for how current these times are.
    var trust: JourneyTrust {
        let time = anchor == .departs ? train.departure : train.arrival
        let journeyPhase: RailJourneyProgress.Phase
        switch phase {
        case .underway: journeyPhase = .underway
        case .arrived: journeyPhase = .ended
        case .upcoming, .cancelled: journeyPhase = .upcoming
        }
        return JourneyTrust(
            freshness: train.freshness, timingBasis: time?.isEstimated == true ? .estimated : .scheduled,
            phase: journeyPhase, referenceDate: date
        )
    }

    /// The trust word on a surface that only holds a relayed copy and cannot check for itself
    /// (Apple Watch). The same word as `trust` while the copy is recent; once the last check
    /// is older than `isRecentlyChecked` allows, the times are Saved, as on the Lock Screen
    /// accessories.
    var relayedTrust: JourneyTrust {
        isRecentlyChecked ? trust : .saved
    }

    /// The trust word and when it was checked, without the word the trust word already
    /// implies: "Live · just now", "Estimated · 3 min ago", "Saved · Not checked yet".
    func compactTrustLine(_ trust: JourneyTrust, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var checked = freshnessText(timeZone: timeZone)
        for prefix in ["Last checked ", "Checked "] where checked.hasPrefix(prefix) {
            checked = String(checked.dropFirst(prefix.count))
            break
        }
        return "\(trust.title) · \(checked)"
    }

    /// How long until the train leaves, or arrives once underway, while that is within ninety
    /// minutes: "25 min", "1 h 05", "Now". Nil further out, when the clock time is the answer.
    var countdownText: String? {
        guard let anchorDate, status != .cancelled, phase != .arrived else { return nil }
        let seconds = anchorDate.timeIntervalSince(date)
        guard seconds > -60, seconds <= 90 * 60 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 0 { return "Now" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    /// The label over the countdown, carrying the clock time it counts to: "Leaves 6:27 PM".
    var countdownLabel: String {
        "\(anchor == .departs ? "Leaves" : "Arrives") \(anchorTimeText)"
    }
}
