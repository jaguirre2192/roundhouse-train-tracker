import Foundation

/// Where a train is in the rider's selected leg at one moment, from timetable and estimate
/// context with separately recorded progress evidence. This never claims the rider boarded.
public enum WidgetTrainPhase: Equatable, Sendable {
    case upcoming(departureSoon: Bool)
    /// `nextStopIndex` indexes `Train.stops`; the alighting stop when nothing else remains.
    case underway(nextStopIndex: Int)
    case arrived
    case cancelled

    public init(train: WidgetTripSnapshot.Train, at date: Date) {
        if train.isCancelled {
            self = .cancelled
            return
        }
        guard let departure = train.departure?.effective, let arrival = train.arrival?.effective else {
            self = .upcoming(departureSoon: false)
            return
        }
        if train.confirmedArrival(at: date) {
            self = .arrived
        } else if let focus = train.observedFocusIndex(at: date) {
            self = focus == 0
                ? .upcoming(departureSoon: date >= departure.addingTimeInterval(-30 * 60))
                : .underway(nextStopIndex: focus)
        } else if date < departure {
            self = .upcoming(departureSoon: date >= departure.addingTimeInterval(-30 * 60))
        } else if date >= arrival {
            self = .underway(nextStopIndex: train.stops.count - 1)
        } else {
            let last = train.stops.count - 1
            let next = train.stops.indices.dropFirst().first { index in
                let stop = train.stops[index]
                guard !stop.isCancelled, let time = index == last ? stop.arrival : stop.departure else { return false }
                return time.effective > date
            }
            self = .underway(nextStopIndex: next ?? last)
        }
    }

    /// Bounded display retention. Expiration without evidence is never an arrival claim.
    public static func finishDate(_ train: WidgetTripSnapshot.Train, at date: Date = .now) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        if train.isCancelled {
            return (train.departure?.timetable).map { $0.addingTimeInterval(WidgetTripSnapshot.arrivalGrace) }
        }
        guard let arrival = train.arrival?.effective else { return nil }
        if train.confirmedArrival(at: date) {
            // Preserve grace for a late source report. GPS-only confirmation does not
            // restart that grace each time another position reaches the widget.
            let reported = train.progressEvidence?.validReportedArrival(at: date) ?? arrival
            return max(arrival, reported).addingTimeInterval(WidgetTripSnapshot.arrivalGrace)
        }
        // This is only bounded display retention, not confirmation the train arrived.
        let observation = train.progressEvidence?.validObservation(at: date) ?? .distantPast
        return max(arrival, observation).addingTimeInterval(2 * 3_600)
    }

    public static func isFinished(_ train: WidgetTripSnapshot.Train, at date: Date) -> Bool {
        guard let finish = finishDate(train, at: date) else { return true }
        return date >= finish
    }
}

/// What the widget shows at one moment.
public enum WidgetDisplay: Equatable, Sendable {
    /// No tracked trains: one line and a way to add a journey.
    case empty
    /// The next relevant train and, when there is one, the train after it.
    case train(WidgetTripSnapshot.Train, following: WidgetTripSnapshot.Train?)
    /// The most recent confirmed-arrived or cancelled train stays visible after retention.
    case ended(WidgetTripSnapshot.Train)

    public init(snapshot: WidgetTripSnapshot?, at date: Date) {
        let trains = (snapshot?.trains ?? []).filter { $0.departure != nil && $0.arrival != nil }
        guard !trains.isEmpty else {
            self = .empty
            return
        }
        let open = trains.filter { !WidgetTrainPhase.isFinished($0, at: date) }
        if let primary = open.first {
            self = .train(primary, following: open.dropFirst().first)
        } else if let last = trains.max(by: { ($0.arrival?.effective ?? .distantPast) < ($1.arrival?.effective ?? .distantPast) }) {
            self = last.confirmedArrival(at: date) || last.isCancelled
                ? .ended(last) : .train(last, following: nil)
        } else {
            self = .empty
        }
    }

    public var primary: WidgetTripSnapshot.Train? {
        switch self {
        case .empty: nil
        case let .train(train, _), let .ended(train): train
        }
    }
}

/// Station-local clock text. The zone abbreviation appears only when the station's clock
/// differs from the device's, matching the app's `zoneSuffix` rule.
public struct WidgetClock: Sendable {
    public let locale: Locale
    public let deviceTimeZone: TimeZone

    public init(locale: Locale = .trainTrackerTime, deviceTimeZone: TimeZone = .autoupdatingCurrent) {
        self.locale = locale
        self.deviceTimeZone = deviceTimeZone
    }

    public func zoneSuffix(_ date: Date, timeZoneIdentifier: String?) -> String? {
        guard let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier),
              zone.secondsFromGMT(for: date) != deviceTimeZone.secondsFromGMT(for: date) else { return nil }
        return zone.abbreviation(for: date) ?? zone.identifier
    }

    /// "6:20 PM" (or "18:20"), in the station's zone when known.
    public func time(_ date: Date, timeZoneIdentifier: String?) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone(timeZoneIdentifier))
        style.calendar = Calendar(identifier: .gregorian)
        return date.formatted(style)
    }

    /// "6:20" or "18:20" without a day period, for the tightest Lock Screen slots.
    public func compactTime(_ date: Date, timeZoneIdentifier: String?) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: zone(timeZoneIdentifier))
            .hour(.defaultDigits(amPM: .omitted)).minute()
        style.calendar = Calendar(identifier: .gregorian)
        return date.formatted(style)
    }

    private func zone(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? deviceTimeZone
    }
}

/// Copy for every widget family, from one train at one moment. Shared vocabulary:
/// "7 min late", "On time", "Canceled", "Track" at Amtrak stations, and `TripFreshness` wording.
public struct WidgetTrainPresentation: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case onTime
        case delayed(minutes: Int)
        /// Only timetable times are known, so punctuality is not claimed.
        case scheduled
        case arrived
        case cancelled
    }

    public enum Anchor: String, Equatable, Sendable {
        case departs = "Departs"
        case arrives = "Arrives"
        case arrived = "Arrived"
    }

    public let train: WidgetTripSnapshot.Train
    public let date: Date
    public let phase: WidgetTrainPhase
    public let clock: WidgetClock

    public init(train: WidgetTripSnapshot.Train, at date: Date, clock: WidgetClock = WidgetClock()) {
        self.train = train
        self.date = date
        self.phase = WidgetTrainPhase(train: train, at: date)
        self.clock = clock
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.train == rhs.train && lhs.date == rhs.date && lhs.phase == rhs.phase
    }

    // MARK: Route

    public var originLabel: String { train.boarding?.label ?? "—" }
    public var destinationLabel: String { train.alighting?.label ?? "—" }
    /// Both ends have letter codes, so the route can be drawn as codes on a rail.
    public var hasCodes: Bool { train.boarding?.code != nil && train.alighting?.code != nil }

    public var nextStop: WidgetTripSnapshot.Stop? {
        if case let .underway(index) = phase, train.stops.indices.contains(index) { return train.stops[index] }
        return nil
    }

    /// Confirmed passage only. A clock estimate cannot fill the journey gauge.
    public var legProgress: Double { train.confirmedProgress(at: date) }

    public var isArrivalUnconfirmed: Bool {
        !train.isCancelled && !train.confirmedArrival(at: date)
            && train.arrival.map { date >= $0.effective } == true
    }

    public var nextStopLabel: String {
        train.observedFocusIndex(at: date) == nil ? "Scheduled next" : "Next stop"
    }

    // MARK: Anchor time

    public var anchor: Anchor {
        switch phase {
        case .upcoming, .cancelled: .departs
        case .underway: .arrives
        case .arrived: .arrived
        }
    }

    private var anchorStop: WidgetTripSnapshot.Stop? {
        anchor == .departs ? train.boarding : train.alighting
    }

    private var anchorTime: WidgetTime? {
        anchor == .departs ? train.departure : train.arrival
    }

    /// The time to plan around: the estimate when late, the timetable time when cancelled.
    public var anchorDate: Date? {
        guard let time = anchorTime else { return nil }
        return status == .cancelled ? time.timetable : time.effective
    }

    public var anchorTimeText: String {
        guard let anchorDate else { return "—" }
        return clock.time(anchorDate, timeZoneIdentifier: anchorStop?.timeZoneIdentifier)
    }

    public var anchorCompactTimeText: String {
        guard let anchorDate else { return "—" }
        return clock.compactTime(anchorDate, timeZoneIdentifier: anchorStop?.timeZoneIdentifier)
    }

    /// The station's zone abbreviation when it differs from the device's ("CET").
    public var anchorZone: String? {
        anchorDate.flatMap { clock.zoneSuffix($0, timeZoneIdentifier: anchorStop?.timeZoneIdentifier) }
    }

    /// The timetable time to strike through beside a 5+ minute late estimate.
    public var struckTimetableText: String? {
        guard case .delayed = status, let scheduled = anchorTime?.scheduled else { return nil }
        return clock.time(scheduled, timeZoneIdentifier: anchorStop?.timeZoneIdentifier)
    }

    public var struckTimetableCompactText: String? {
        guard case .delayed = status, let scheduled = anchorTime?.scheduled else { return nil }
        return clock.compactTime(scheduled, timeZoneIdentifier: anchorStop?.timeZoneIdentifier)
    }

    // MARK: Status

    public var status: Status {
        if isArrivalUnconfirmed { return .scheduled }
        switch phase {
        case .cancelled: return .cancelled
        case .arrived:
            return .arrived
        case .upcoming, .underway:
            let relevant: WidgetTime? = {
                switch phase {
                case .upcoming: return train.departure
                default: return nextStop.flatMap { $0 == train.alighting ? $0.arrival : $0.departure } ?? train.arrival
                }
            }()
            guard let relevant, relevant.isEstimated else { return .scheduled }
            if let delay = relevant.delayMinutes, delay >= 5 { return .delayed(minutes: delay) }
            return .onTime
        }
    }

    public var statusText: String {
        if isArrivalUnconfirmed { return "Arrival unconfirmed" }
        return switch status {
        case .onTime: RunningStatusWords.onTime
        case let .delayed(minutes): RunningStatusWords.late(minutes)
        case .scheduled: JourneyTrust.timetable.title
        case .arrived: RunningStatusWords.arrived
        case .cancelled: RunningStatusWords.canceled
        }
    }

    // MARK: Platform

    /// The rider's platform: boarding before departure, alighting once underway.
    public var platformStop: WidgetTripSnapshot.Stop? {
        anchor == .departs ? train.boarding : train.alighting
    }

    /// "Track" at Amtrak stations, never "Platform".
    public var platformNoun: String { platformStop?.platformNoun ?? "Platform" }

    /// Nil when cancelled or finished: a past or void assignment is not guidance.
    public var platformValue: String? {
        guard status != .cancelled, status != .arrived, !isArrivalUnconfirmed else { return nil }
        return platformStop?.platform
    }

    /// "Track 7", or "Track —" so the slot keeps its shape.
    public var platformText: String { "\(platformNoun) \(platformValue ?? "—")" }

    // MARK: Freshness

    public func freshnessText(timeZone: TimeZone = .autoupdatingCurrent) -> String {
        train.freshness.text(at: date, timeZone: timeZone, style: .compact)
    }

    /// A successful check within 15 minutes; otherwise accessories mark the times as saved.
    public var isRecentlyChecked: Bool {
        guard !train.lastRefreshFailed, let check = train.lastSuccessfulCheck else { return false }
        return date.timeIntervalSince(check) <= 15 * 60
    }

    // MARK: Lock Screen copy

    /// "NYP 6:20 · +7 min", "Arr. PHL 7:52 · On time", "Arrived PHL 7:52".
    public var inlineText: String {
        if isArrivalUnconfirmed { return "Arrival unconfirmed" }
        let zone = anchorZone.map { " \($0)" } ?? ""
        let time = anchorCompactTimeText + zone
        // A station without a letter code is too long beside the clock; lead with the time.
        let origin = train.boarding?.code
        let destination = train.alighting?.code
        switch phase {
        case .arrived: return destination.map { "Arrived \($0) \(time)" } ?? "Arrived \(time)"
        case .cancelled: return "\(origin ?? "Dep.") \(time) · Canceled"
        case .underway: return "Arr. \(destination.map { "\($0) " } ?? "")\(time) · \(inlineDetail)"
        case .upcoming: return "\(origin ?? "Dep.") \(time) · \(inlineDetail)"
        }
    }

    private var inlineDetail: String {
        if status == .scheduled, let platform = platformValue { return "\(platformNoun) \(platform)" }
        if case let .delayed(minutes) = status { return "+\(minutes) min" }
        return statusText
    }

    /// Third line of the rectangular accessory: where to go, or what comes next.
    public var rectangularDetail: String {
        if isArrivalUnconfirmed { return "Check latest train status" }
        let saved = isRecentlyChecked ? "" : " · Saved"
        switch phase {
        case .cancelled: return "Check operator advice"
        case .arrived: return "Journey ended"
        case .underway:
            guard let nextStop, let time = (nextStop == train.alighting ? nextStop.arrival : nextStop.departure) else {
                return platformText + saved
            }
            return "\(nextStopLabel) \(nextStop.label) \(clock.compactTime(time.effective, timeZoneIdentifier: nextStop.timeZoneIdentifier))" + saved
        case .upcoming: return platformText + saved
        }
    }

    public var nextStopTimeText: String? {
        guard let nextStop, let time = (nextStop == train.alighting ? nextStop.arrival : nextStop.departure) else { return nil }
        return clock.time(time.effective, timeZoneIdentifier: nextStop.timeZoneIdentifier)
    }

    public var arrivalTimeText: String {
        guard let arrival = train.arrival else { return "—" }
        return clock.time(arrival.effective, timeZoneIdentifier: train.alighting?.timeZoneIdentifier)
    }

    public var accessibilitySummary: String {
        var parts = [train.serviceName, "\(train.boarding?.name ?? originLabel) to \(train.alighting?.name ?? destinationLabel)"]
        let zone = anchorZone.map { " \($0)" } ?? ""
        parts.append("\(isArrivalUnconfirmed ? "Timetable arrival" : anchor.rawValue) \(anchorTimeText)\(zone)")
        switch status {
        case let .delayed(minutes): parts.append("\(minutes) minutes late, timetable \(struckTimetableText ?? "")")
        default: parts.append(statusText)
        }
        if let nextStop, let time = nextStopTimeText { parts.append("\(nextStopLabel) \(nextStop.name) \(time)") }
        if let platform = platformValue { parts.append("\(platformNoun) \(platform)") }
        parts.append(freshnessText())
        return parts.joined(separator: ". ")
    }
}

public extension WidgetTripSnapshot {
    /// Moments after `date` when the widget's view changes without new data: departure soon,
    /// departure, each call, arrival, the hand-over to the next train, freshness wording
    /// ("Checked 3 min ago") and gauge steps. Bounded to a day and `limit` entries.
    func timelineDates(after date: Date, limit: Int = 120) -> [Date] {
        var dates: Set<Date> = []
        let horizon = date.addingTimeInterval(24 * 3_600)
        for train in trains {
            guard let departure = train.departure?.effective, let arrival = train.arrival?.effective else { continue }
            dates.insert(departure.addingTimeInterval(-30 * 60))
            dates.insert(departure)
            dates.insert(arrival)
            if let finish = WidgetTrainPhase.finishDate(train, at: date) { dates.insert(finish) }
            if let observation = train.progressEvidence?.validObservation(at: date) { dates.insert(observation.addingTimeInterval(300.001)) }
            for stop in train.stops.dropFirst() {
                if let time = stop.departure?.effective { dates.insert(time) }
                if let time = stop.arrival?.effective { dates.insert(time) }
            }
            // The circular gauge drains over the last hour, then tracks the leg.
            for minutes in stride(from: 60, to: 0, by: -5) {
                dates.insert(departure.addingTimeInterval(-Double(minutes) * 60))
            }
            var tick = departure.addingTimeInterval(600)
            while tick < arrival {
                dates.insert(tick)
                tick.addTimeInterval(600)
            }
            if let check = train.lastSuccessfulCheck, !train.lastRefreshFailed {
                for minutes in Array(1...10) + Array(stride(from: 15, through: 60, by: 5)) {
                    dates.insert(check.addingTimeInterval(Double(minutes) * 60))
                }
            }
        }
        return dates.filter { $0 > date && $0 <= horizon }.sorted().prefix(limit).map { $0 }
    }
}
