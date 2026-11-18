import Foundation

/// How far the times on screen can be trusted, as one word. The rail chip, the ticket, the map
/// and the Lock Screen all read it, so a journey never claims "live" in one place and "not
/// checked" in another.
public enum JourneyTrust: String, Equatable, Sendable {
    /// Checked within the last five minutes while the train is running, with operator estimates.
    case live
    /// Checked this session; times are the operator's estimates.
    case estimated
    /// Checked this session; the operator publishes only the timetable.
    case timetable
    /// Not checked this session, or the last check failed: times are the last ones saved.
    case saved

    /// How long a check keeps a running train "live".
    public static let liveWindow: TimeInterval = 5 * 60

    public init(
        freshness: TripFreshness,
        timingBasis: RailJourneyProgress.TimingBasis,
        phase: RailJourneyProgress.Phase,
        referenceDate: Date
    ) {
        guard case let .checked(date) = freshness else {
            self = .saved
            return
        }
        guard timingBasis == .estimated else {
            self = .timetable
            return
        }
        let age = referenceDate.timeIntervalSince(date)
        self = phase == .underway && age >= 0 && age <= Self.liveWindow ? .live : .estimated
    }

    public var title: String {
        switch self {
        case .live: "Live"
        case .estimated: "Estimated"
        case .timetable: "Timetable"
        case .saved: "Saved"
        }
    }

    /// The word followed by when it was checked: "Live · Checked just now",
    /// "Saved · Not checked yet".
    public func line(freshness: TripFreshness, at referenceDate: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        "\(title) · \(freshness.text(at: referenceDate, timeZone: timeZone, style: .compact))"
    }

    public var systemImage: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .estimated: "clock.badge.checkmark"
        case .timetable: "calendar"
        case .saved: "clock.arrow.circlepath"
        }
    }

    /// Whether anything on screen may present itself as current.
    public var isConfirmed: Bool { self != .saved }
}
