import Foundation

/// One vocabulary for how recently a train's details were checked, shared by My Trips,
/// the live ticket, train and journey detail, connection checks and the Live Activity.
public enum TripFreshness: Equatable, Sendable {
    case checkFailed
    case notChecked
    case checked(Date)

    public init(lastSuccessfulCheck: Date?, lastRefreshFailed: Bool) {
        if lastRefreshFailed {
            self = .checkFailed
        } else if let lastSuccessfulCheck {
            self = .checked(lastSuccessfulCheck)
        } else {
            self = .notChecked
        }
    }

    /// Whether the times on screen come from a check made this session. Saved estimates
    /// are still shown, but never with the same confidence as checked ones.
    public var isConfirmed: Bool {
        if case .checked = self { return true }
        return false
    }

    public enum Style: Sendable {
        /// Standalone status lines: says what is shown after a failure.
        case full
        /// After a timing basis on the ticket ("Estimated times · Check failed").
        case compact
    }

    /// "Check failed · Saved times shown", "Not checked yet", "Checked 3 min ago", or
    /// "Last checked 7:04 PM" after an hour.
    public func text(at referenceDate: Date, timeZone: TimeZone = .autoupdatingCurrent, style: Style = .full) -> String {
        switch self {
        case .checkFailed:
            return style == .compact ? "Check failed" : "Check failed · Saved times shown"
        case .notChecked:
            return "Not checked yet"
        case let .checked(date):
            let minutes = Int(max(0, referenceDate.timeIntervalSince(date)) / 60)
            if minutes < 1 { return "Checked just now" }
            if minutes < 60 { return "Checked \(minutes) min ago" }
            let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: .trainTrackerTime, timeZone: timeZone))
            return "Last checked \(time)"
        }
    }
}
