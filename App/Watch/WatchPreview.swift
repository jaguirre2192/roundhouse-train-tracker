#if DEBUG
import SwiftUI
import TrainTrackerCore

/// Fixture data for running a DEBUG build of the watch app without a phone, so every state
/// can be checked in the simulator. The whole file is left out of Release builds.
///
///     -WatchPreview [-WatchPreviewState upcoming|underway|empty|…] [-WatchPreviewWake on|asking|waiting|denied]
///     [-WatchPreviewFocus wake] [-WatchPreviewTextSize ax1|ax2|ax3]
///
/// The journey is New York Penn to Philadelphia, timed from the minute the app launched, the
/// same sample the widget gallery uses.
struct WatchPreview {
    enum State: String, CaseIterable {
        case upcoming, underway, empty, delayed, far, saved, canceled, ended, names, two, waitingForPhone = "waiting-for-phone"
    }

    let payload: WatchPayload?
    /// A wake request held unanswered, to show the pending states.
    let heldRequest: (request: WatchWakeRequest, isStalled: Bool)?
    /// Opens scrolled to the wake switch.
    let focusesWake: Bool

    static func fromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard
    ) -> WatchPreview? {
        guard arguments.contains("-WatchPreview") else { return nil }
        let state = defaults.string(forKey: "WatchPreviewState").flatMap(State.init(rawValue:)) ?? .upcoming
        return WatchPreview(
            state: state, wake: defaults.string(forKey: "WatchPreviewWake"),
            focusesWake: defaults.string(forKey: "WatchPreviewFocus") == "wake"
        )
    }

    init(state: State, wake: String? = nil, focusesWake: Bool = false, at launch: Date = .now) {
        // From the top of the minute, so a countdown reads the same for the whole first minute.
        let now = Date(timeIntervalSinceReferenceDate: (launch.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let checked = now.addingTimeInterval(-60)
        self.focusesWake = focusesWake
        var held: (request: WatchWakeRequest, isStalled: Bool)?

        let trains: [WidgetTripSnapshot.Train]?
        switch state {
        case .waitingForPhone: trains = nil
        case .empty: trains = []
        case .upcoming: trains = [Self.acela(at: now, departure: 12, delay: 1, checked: checked)]
        case .underway: trains = [Self.acela(at: now, departure: -42, delay: 2, checked: checked)]
        case .delayed: trains = [Self.acela(at: now, departure: 18, delay: 7, checked: checked)]
        case .far: trains = [Self.acela(at: now, departure: 185, delay: nil, checked: checked)]
        case .saved: trains = [Self.acela(at: now, departure: 24, delay: 9, checked: now.addingTimeInterval(-40 * 60))]
        case .canceled: trains = [Self.acela(at: now, departure: 35, delay: nil, checked: checked, canceled: true)]
        case .ended: trains = [Self.acela(at: now, departure: -160, delay: 0, checked: checked)]
        case .names: trains = [Self.tgv(at: now, checked: checked)]
        case .two:
            trains = [
                Self.acela(at: now, departure: 12, delay: 1, checked: checked),
                Self.acela(at: now, number: "2155", departure: 150, delay: nil, checked: checked),
            ]
        }
        guard let trains else {
            payload = nil
            heldRequest = nil
            return
        }

        var alerts: [String: Int] = [:]
        var replies: [String: WatchWakeReply] = [:]
        if let first = trains.first {
            // Underway is shown with the alert on unless asked otherwise.
            switch wake ?? (state == .underway ? "on" : "off") {
            case "on": alerts[first.id] = WatchWakeRequest.defaultLead
            case "asking", "waiting":
                held = (
                    WatchWakeRequest(tripID: first.id, stopID: nil, leadMinutes: WatchWakeRequest.defaultLead, sentAt: now),
                    wake == "waiting"
                )
            case "denied": replies[first.id] = WatchWakeReply(requestID: "preview", outcome: .notificationsDenied)
            default: break
            }
        }
        heldRequest = held
        payload = WatchPayload(
            generatedAt: now, snapshot: WidgetTripSnapshot(generatedAt: now, trains: trains),
            wakeAlerts: alerts, wakeReplies: replies
        )
    }

    private static func acela(
        at date: Date, number: String = "2151", departure: Double, delay: Double?, checked: Date?, canceled: Bool = false
    ) -> WidgetTripSnapshot.Train {
        func time(_ minutes: Double) -> Date { date.addingTimeInterval(minutes * 60) }
        func expected(_ minutes: Double) -> Date? { delay.map { time(minutes + $0) } }
        let zone = TimeZone.autoupdatingCurrent.identifier
        func stop(_ name: String, _ code: String, arrival: Double?, departure: Double?, platform: String? = nil) -> WidgetTripSnapshot.Stop {
            WidgetTripSnapshot.Stop(
                name: name, code: code, timeZoneIdentifier: zone,
                scheduledArrival: arrival.map(time), scheduledDeparture: departure.map(time),
                expectedArrival: arrival.flatMap(expected), expectedDeparture: departure.flatMap(expected),
                platform: platform, platformKind: .track, isCancelled: canceled
            )
        }
        return WidgetTripSnapshot.Train(
            id: "sample:amtrak:\(number)", serviceName: "Acela \(number)",
            stops: [
                stop("New York Penn Station", "NYP", arrival: nil, departure: departure, platform: "7"),
                stop("Newark Penn Station", "NWK", arrival: departure + 15, departure: departure + 17),
                stop("Trenton", "TRE", arrival: departure + 45, departure: departure + 46),
                stop("Philadelphia 30th Street", "PHL", arrival: departure + 80, departure: nil, platform: "4"),
            ],
            lastSuccessfulCheck: checked
        )
    }

    /// Stations without letter codes, and a timetable-only operator.
    private static func tgv(at date: Date, checked: Date) -> WidgetTripSnapshot.Train {
        func time(_ minutes: Double) -> Date { date.addingTimeInterval(minutes * 60) }
        let zone = TimeZone.autoupdatingCurrent.identifier
        return WidgetTripSnapshot.Train(
            id: "sample:sncf:6611", serviceName: "TGV INOUI 6611",
            stops: [
                WidgetTripSnapshot.Stop(
                    name: "Paris Gare de Lyon", timeZoneIdentifier: zone,
                    scheduledDeparture: time(45), platform: "K", platformKind: .platform
                ),
                WidgetTripSnapshot.Stop(name: "Lyon Part-Dieu", timeZoneIdentifier: zone, scheduledArrival: time(161), platformKind: .platform),
            ],
            lastSuccessfulCheck: checked
        )
    }
}

extension View {
    /// Applies `-WatchPreviewTextSize` under `-WatchPreview`; the watch simulator cannot be
    /// given a text size from the command line.
    @ViewBuilder
    func watchPreviewTextSize() -> some View {
        let sizes: [String: DynamicTypeSize] = ["ax1": .accessibility1, "ax2": .accessibility2, "ax3": .accessibility3]
        if ProcessInfo.processInfo.arguments.contains("-WatchPreview"),
           let size = UserDefaults.standard.string(forKey: "WatchPreviewTextSize").flatMap({ sizes[$0] }) {
            dynamicTypeSize(size)
        } else {
            self
        }
    }
}
#endif
