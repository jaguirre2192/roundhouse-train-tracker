import Foundation
import TrainTrackerCore

/// Passenger-facing copy is kept separate from timetable-based progress.
struct JourneyExperiencePresentation {
    let trip: TrainTrip
    let progress: RailJourneyProgress
    let timeZones: TripDetailTimeZoneContext
    let referenceDate: Date
    let lastSuccessfulCheck: Date?
    let refreshFailed: Bool
    let selectedSegment: JourneyPlanSegment?

    init(
        trip: TrainTrip,
        timeZones: TripDetailTimeZoneContext,
        referenceDate: Date,
        lastSuccessfulCheck: Date? = nil,
        refreshFailed: Bool = false,
        selectedSegment: JourneyPlanSegment? = nil
    ) {
        self.trip = trip
        self.timeZones = timeZones
        self.referenceDate = referenceDate
        self.lastSuccessfulCheck = lastSuccessfulCheck
        self.refreshFailed = refreshFailed
        self.selectedSegment = selectedSegment
        if let selectedSegment {
            progress = RailJourneyProgress(
                trip: trip,
                referenceDate: referenceDate,
                boardingPlace: selectedSegment.from,
                alightingPlace: selectedSegment.to
            )
        } else {
            progress = RailJourneyProgress(trip: trip, referenceDate: referenceDate)
        }
    }

    var routeTitle: String {
        "\(originName) → \(destinationName)"
    }

    var originName: String {
        selectedSegment?.from.displayName ?? progress.stops.first?.station.displayName ?? trip.origin?.displayName ?? "Origin unavailable"
    }

    var destinationName: String {
        selectedSegment?.to.displayName ?? progress.stops.last?.station.displayName ?? trip.destination?.displayName ?? "Destination unavailable"
    }

    var serviceTitle: String {
        trip.product.localizedCaseInsensitiveContains(trip.operatorName)
            ? trip.product : "\(trip.operatorName) · \(trip.product)"
    }

    var phaseTitle: String {
        if progress.isCancelled { return RunningStatusWords.canceled }
        if hasCancelledBoundary { return "Stop canceled" }
        return switch progress.phase {
        case .upcoming: "Upcoming"
        case .departureSoon: "Departure soon"
        case .underway: "Journey underway"
        case .ended: progress.evidence.isArrivalConfirmed ? RunningStatusWords.arrived : RunningStatusWords.arrivalUnconfirmed
        case .unavailable: "Details unavailable"
        }
    }

    var focusLabel: String {
        if progress.isCancelled { return "Check your travel options" }
        if progress.stops.first?.isCancelled == true { return "Boarding stop" }
        if progress.stops.last?.isCancelled == true { return "Arrival stop" }
        return switch progress.phase {
        case .upcoming, .departureSoon: "Departing from"
        case .underway:
            focusUsesEstimate && needsRefresh ? "Next stop from saved times" : progress.nextStopRole
        case .ended: "Destination"
        case .unavailable: "Your journey"
        }
    }

    var focusName: String {
        cancelledBoundary?.station.displayName ?? progress.focusStop?.station.displayName
            ?? (progress.phase == .ended ? destinationName : routeTitle)
    }

    /// The clock can move the timetable focus to the next station without the train ever
    /// reporting the previous call. Surface that gap where the rider reads their next stop.
    var unreportedScheduledStopText: String? {
        guard progress.phase == .underway, progress.evidence.basis == .unconfirmed,
              !progress.isCancelled, !hasCancelledBoundary,
              let focus = progress.focusStop, !focusUsesEstimate else { return nil }
        let previous = progress.stops.dropFirst().last { stop in
            guard stop.sequence < focus.sequence, !stop.isCancelled,
                  let due = stop.scheduledArrival, due <= referenceDate else { return false }
            return !stop.hasConfirmedArrival(at: referenceDate) && !ArrivalEvidence.hasReached(stop, progress: progress)
        }
        return previous.map { "Arrival at \($0.station.displayName) unconfirmed" }
    }

    var focusDate: Date? {
        guard !progress.isCancelled, !hasCancelledBoundary else { return nil }
        return switch progress.phase {
        case .upcoming, .departureSoon: progress.departureDate
        case .underway:
            progress.focusStop.flatMap { $0.expectedArrival ?? $0.scheduledArrival ?? $0.expectedDeparture ?? $0.scheduledDeparture }
        case .ended: progress.arrivalDate
        case .unavailable: nil
        }
    }

    /// Names the event the focus time describes. Before boarding it is the boarding departure;
    /// underway it is the next stop's arrival, which can differ from the departure the route
    /// timeline lists for the same stop (for example arriving 6:44, departing 6:46).
    var timingLabel: String {
        switch progress.phase {
        case .ended: return focusUsesEstimate ? "Last arrival estimate" : RunningStatusWords.timeLabel(.timetable, event: "arrival")
        default:
            let event = focusTiming?.eventNoun
                ?? (progress.phase == .underway ? "arrival" : "departure")
            let trust: JourneyTrust = focusUsesEstimate ? (needsRefresh ? .saved : .estimated) : .timetable
            return RunningStatusWords.timeLabel(trust, event: event)
        }
    }

    var focusTimeText: String? {
        focusDate.map { JourneyExperienceClock.time($0, zone: focusTimeZone) }
    }

    var countdownText: String? {
        guard let focusDate, progress.phase != .ended, progress.phase != .unavailable else { return nil }
        let minutes = Int(ceil(focusDate.timeIntervalSince(referenceDate) / 60))
        guard minutes >= 0, minutes < 180 else { return nil }
        if minutes == 0 { return "Due now" }
        if minutes < 60 { return "In \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "In \(hours) hr" : "In \(hours) hr \(remainder) min"
    }

    var focusTimeZone: String? {
        if let stop = progress.focusStop { return timeZones.timeZoneIdentifier(for: stop) }
        if progress.phase == .ended {
            return selectedSegment?.to.timeZoneIdentifier
                ?? progress.stops.last.flatMap { timeZones.timeZoneIdentifier(for: $0) }
                ?? timeZones.routeTimeZones?.arrivalTimeZoneIdentifier
        }
        return selectedSegment?.from.timeZoneIdentifier
            ?? progress.stops.first.flatMap { timeZones.timeZoneIdentifier(for: $0) }
            ?? timeZones.routeTimeZones?.departureTimeZoneIdentifier
    }

    /// "Track" or "Platform" for the boarding or next stop the next-step card describes.
    var platformNoun: String {
        progress.focusStop?.platformNoun ?? "Platform"
    }

    /// The live feed credited for the assignment, for example "Amtraker".
    var platformSourceName: String? {
        progress.focusStop?.platformSource
    }

    var platformGuidance: PlatformGuidance {
        guard !progress.isCancelled, !hasCancelledBoundary, progress.phase != .ended else { return .unavailable }
        return progress.focusStop?.platformGuidance(at: referenceDate) ?? .unavailable
    }

    var supportingText: String {
        if progress.isCancelled { return "This service is marked canceled. Check the operator’s latest travel advice." }
        if hasCancelledBoundary {
            return "This train is marked as not stopping at this station. Check the operator’s advice before continuing your journey."
        }
        if progress.phase == .unavailable {
            return selectedSegment == nil
                ? "Timetable details are unavailable. Refresh to try again."
                : "The available stops couldn’t be matched to your saved route. Check your journey details below."
        }
        if progress.phase == .ended {
            return focusUsesEstimate
                ? "The last estimated arrival time has passed."
                : "The timetable arrival time has passed."
        }
        return focusUsesEstimate
            ? (needsRefresh ? "Saved estimates. Refresh for the latest available details." : "Times are estimates from the rail provider.")
            : "Based on the timetable. Check station displays for changes."
    }

    var checkText: String {
        TripFreshness(lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: refreshFailed).text(
            at: referenceDate,
            timeZone: focusTimeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        )
    }

    var needsRefresh: Bool {
        refreshFailed || (lastSuccessfulCheck.map { referenceDate.timeIntervalSince($0) > 300 } ?? true)
    }

    var currentAlerts: [RailAlert] {
        trip.alerts.filter {
            ($0.validFrom == nil || $0.validFrom! <= referenceDate)
                && ($0.validUntil == nil || $0.validUntil! > referenceDate)
        }.sorted { severity($0) > severity($1) }
    }

    var isDisrupted: Bool {
        progress.isCancelled || hasCancelledBoundary || (focusTiming?.delayMinutes ?? 0) >= 5
            || currentAlerts.contains { $0.severity == .major || $0.severity == .critical }
    }

    var delayText: String? {
        guard !progress.isCancelled, !hasCancelledBoundary,
              let minutes = focusTiming?.delayMinutes, minutes >= 5 else { return nil }
        return RunningStatusWords.late(minutes)
    }

    var stationMapURL: URL? {
        guard !hasCancelledBoundary, let station = progress.focusStop?.station,
              station.location.latitude != 0 || station.location.longitude != 0 else { return nil }
        var url = URLComponents(string: "https://maps.apple.com/")
        url?.queryItems = [
            URLQueryItem(name: "ll", value: "\(station.location.latitude),\(station.location.longitude)"),
            URLQueryItem(name: "q", value: station.displayName)
        ]
        return url?.url
    }

    /// The destination city shown as the live ticket's photo strip, so the ticket keeps one
    /// identity for the whole journey. Only the station's public name and coordinates are used.
    var cityPhotoQuery: CityPhotoQuery? {
        guard !progress.isCancelled,
              progress.phase == .upcoming || progress.phase == .departureSoon || progress.phase == .underway,
              let station = progress.stops.last?.station else { return nil }
        return CityPhotoQuery(station: station)
    }

    var hasCancelledBoundary: Bool { cancelledBoundary != nil }

    private var cancelledBoundary: StopTime? {
        if let first = progress.stops.first, first.isCancelled { return first }
        if let last = progress.stops.last, last.isCancelled { return last }
        return nil
    }

    private var focusTiming: StopTimelineTimePresentation? {
        let stop = progress.phase == .ended ? progress.stops.last : progress.focusStop
        guard let stop else { return nil }
        return StopTimelineTimePresentation(
            stop: stop,
            event: progress.phase == .upcoming || progress.phase == .departureSoon ? .departure : .arrival
        )
    }

    private var focusUsesEstimate: Bool {
        focusTiming?.timingBasis == .estimated
    }

    private func severity(_ alert: RailAlert) -> Int {
        switch alert.severity {
        case .information: 0
        case .minor: 1
        case .major: 2
        case .critical: 3
        }
    }
}

enum JourneyExperienceClock {
    static func time(_ date: Date, zone: String?) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened,
            locale: .trainTrackerTime,
            timeZone: zone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        ))
    }

    /// `time` with the station zone's abbreviation when it differs from the device's clock.
    static func labeledTime(_ date: Date, zone: String?, deviceTimeZone: TimeZone = .autoupdatingCurrent) -> String {
        let time = time(date, zone: zone)
        guard let suffix = JourneyPlanDateTimePresentation.zoneSuffix(
            date, timeZoneIdentifier: zone, deviceTimeZone: deviceTimeZone
        ) else { return time }
        return "\(time) \(suffix)"
    }

    static func date(_ date: Date, zone: String?) -> String {
        date.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted,
            locale: .autoupdatingCurrent,
            timeZone: zone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        ))
    }
}
