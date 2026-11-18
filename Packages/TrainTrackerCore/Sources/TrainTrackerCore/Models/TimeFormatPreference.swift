import Foundation

/// How clock times are written: the device's own 12- or 24-hour style, or a fixed choice made
/// in Settings. Stored in the shared App Group so widgets and Live Activities match the app.
public enum TimeFormatPreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case twelveHour
    case twentyFourHour

    public static let key = "preference.timeFormat"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "Automatic"
        case .twelveHour: "12-Hour"
        case .twentyFourHour: "24-Hour"
        }
    }

    /// The shared store the app, widgets and Live Activities all read.
    public static var sharedDefaults: UserDefaults? { SharedDefaults.store }

    public static func stored(in defaults: UserDefaults? = sharedDefaults) -> TimeFormatPreference {
        defaults?.string(forKey: key).flatMap(TimeFormatPreference.init(rawValue:)) ?? .system
    }

    public func uses24HourClock(deviceLocale: Locale = .autoupdatingCurrent) -> Bool {
        switch self {
        case .twelveHour: return false
        case .twentyFourHour: return true
        case .system:
            switch deviceLocale.hourCycle {
            case .zeroToTwentyThree, .oneToTwentyFour: return true
            default: return false
            }
        }
    }

    /// A fixed `DateFormatter` pattern for a station-local clock time: "2:25 PM" or "14:25".
    public func clockPattern(deviceLocale: Locale = .autoupdatingCurrent) -> String {
        uses24HourClock(deviceLocale: deviceLocale) ? "HH:mm" : "h:mm a"
    }

    /// `base` with this hour cycle applied, for locale-driven format styles.
    public func locale(basedOn base: Locale = .autoupdatingCurrent) -> Locale {
        guard self != .system else { return base }
        var components = Locale.Components(locale: base)
        components.hourCycle = self == .twentyFourHour ? .zeroToTwentyThree : .oneToTwelve
        return Locale(components: components)
    }

    private enum SharedDefaults {
        #if os(watchOS)
        // The watch app is not a member of the App Group, so there is nothing shared to read:
        // times follow the watch's own 12- or 24-hour setting.
        nonisolated(unsafe) static let store: UserDefaults? = nil
        #else
        // UserDefaults is thread-safe; one instance serves every formatting call.
        nonisolated(unsafe) static let store = UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)
        #endif
    }
}

public extension Locale {
    /// The traveller's locale with the Settings time format applied.
    static var trainTrackerTime: Locale { TimeFormatPreference.stored().locale() }
}
