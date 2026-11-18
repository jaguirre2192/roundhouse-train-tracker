import Foundation

/// The words for how a train is running. They are kept apart from the trust words
/// (`JourneyTrust`: Live, Estimated, Timetable, Saved), which say how current the data is.
/// Every surface (app, widgets, Lock Screen, watch) takes its wording from here so a rider
/// reads the same thing everywhere.
public enum RunningStatusWords {
    public static let onTime = "On time"
    public static let canceled = "Canceled"
    public static let arrived = "Arrived"
    /// The journey's time has passed. Used where nothing reports the arrival itself, so the
    /// words do not claim one.
    public static let ended = "Journey ended"
    /// The timetable for the journey has run out and nothing reports the train at its
    /// destination. It may simply be late, so nothing is said to have finished.
    public static let arrivalUnconfirmed = "Arrival unconfirmed"
    /// Shown where a status would go but nothing is known about how the train is running.
    public static let noTimes = "No times yet"

    public static func late(_ minutes: Int) -> String { "\(minutes) min late" }
    public static func early(_ minutes: Int) -> String { "\(minutes) min early" }

    /// "7 min late", "3 min early", or nil when the train is on its timetable time.
    public static func difference(minutes: Int) -> String? {
        if minutes > 0 { return late(minutes) }
        if minutes < 0 { return early(-minutes) }
        return nil
    }

    /// The same, with the unit spelled out for speech: "7 minutes late", "1 minute early".
    public static func spokenDifference(minutes: Int) -> String? {
        guard minutes != 0 else { return nil }
        let count = abs(minutes)
        return "\(count) \(count == 1 ? "minute" : "minutes") \(minutes > 0 ? "late" : "early")"
    }

    /// A label for a time that names where it comes from with a trust word:
    /// "Estimated arrival", "Timetable departure", "Saved arrival".
    public static func timeLabel(_ trust: JourneyTrust, event: String) -> String {
        "\(trust.title) \(event)"
    }
}
