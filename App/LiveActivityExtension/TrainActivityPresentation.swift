import Foundation
import TrainTrackerCore

/// Copy and formatting shared by every Live Activity size. No network or lifecycle work.
struct TrainActivityPresentation {
    let attributes: TrainJourneyAttributes
    let state: TrainLiveActivityState
    let isStale: Bool
    let referenceDate: Date

    init(
        attributes: TrainJourneyAttributes,
        state: TrainLiveActivityState,
        isStale: Bool,
        referenceDate: Date = .now
    ) {
        self.attributes = attributes
        self.state = state
        self.referenceDate = referenceDate
        self.isStale = isStale || state.checkedAt == nil
            || !state.validUntil.isFinite || state.validUntil <= referenceDate.timeIntervalSince1970
    }

    var isCancelled: Bool { state.phase == .cancelled || state.isStopCancelled }
    var isEnded: Bool { state.phase == .ended }
    var hasDelay: Bool { !isCancelled && !isEnded && (state.delayMinutes ?? 0) >= 5 }

    /// How recently this activity's details were checked, in the app's shared vocabulary.
    var freshness: TripFreshness {
        TripFreshness(lastSuccessfulCheck: state.checkedAt.map(Date.init(timeIntervalSince1970:)), lastRefreshFailed: false)
    }

    var phaseTitle: String {
        if state.isStopCancelled { return "Stop canceled" }
        switch state.phase {
        case .cancelled: return RunningStatusWords.canceled
        case .ended: return "Journey ended"
        case .unavailable: return "Details unavailable"
        default:
            if isStale { return freshness.isConfirmed ? "Saved times" : "Not checked yet" }
            switch state.phase {
            case .upcoming: return "Upcoming"
            case .departureSoon: return "Departure soon"
            case .underway: return "Journey underway"
            default: return "Your journey"
            }
        }
    }

    /// The island's status: the Lock Screen pill's words (and the app's stage names), with
    /// shorter forms only where the island has no room.
    var shortStatus: String {
        if isCancelled { return RunningStatusWords.canceled }
        if isEnded { return "Ended" }
        if isStale { return "Saved" }
        if hasDelay, let delay = state.delayMinutes { return RunningStatusWords.late(delay) }
        return phaseTitle
    }

    var headerStatus: String {
        if !isStale, hasDelay, let delay = state.delayMinutes { return "Est. +\(delay) min" }
        return phaseTitle
    }

    /// A status glyph, never an action: the island can only open the app, so a refresh
    /// arrow there reads as a control that doesn't exist. Saved data is dimmed instead.
    var symbol: String {
        if isCancelled { return "xmark.circle.fill" }
        if isEnded { return "clock" }
        return TrainTrackerSymbol.train
    }

    var focusLabel: String {
        if isCancelled { return "Check travel options" }
        if isEnded { return "Destination" }
        if isStale { return "From saved details" }
        switch state.phase {
        case .upcoming, .departureSoon: return "Departing from"
        case .underway: return state.timingBasis == .estimated ? "Next expected stop" : "Next scheduled stop"
        default: return "Selected journey"
        }
    }

    /// A stub-sized label; the pill and accessibility summary carry saved-versus-live detail.
    var stubFocusLabel: String {
        if isCancelled { return "Status" }
        if isEnded { return "Arrived" }
        switch state.phase {
        case .upcoming, .departureSoon: return "Board at"
        case .underway: return "Next stop"
        default: return "Journey"
        }
    }

    /// The focus station as a code when it is one of the ticket's ends and has one.
    var stubFocusValue: String {
        let name = focusName
        if name == attributes.originName, let code = attributes.originCode { return code }
        if name == attributes.destinationName, let code = attributes.destinationCode { return code }
        return name
    }

    var focusName: String {
        let name = state.focusName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Journey details" : name
    }

    var eventDate: Date? {
        guard !isCancelled, state.phase != .unavailable, state.timingBasis != .unavailable,
              let timestamp = state.eventTime, timestamp.isFinite else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// The last half hour before boarding counts down by itself on the Lock Screen, between
    /// pushes. Saved data never counts down: a stale time could already be wrong.
    var finalApproach: ClosedRange<Date>? {
        guard state.phase == .departureSoon, !isStale, let eventDate, eventDate > referenceDate else { return nil }
        return referenceDate...eventDate
    }

    var timingLabel: String {
        if isEnded { return state.timingBasis == .estimated ? "Last arrival estimate" : "Timetable arrival" }
        switch state.timingBasis {
        case .scheduled: return JourneyTrust.timetable.title
        case .estimated: return isStale ? "Saved estimate" : "Estimated"
        case .unavailable: return "Time unavailable"
        }
    }

    /// Stub-sized: "Saved" rather than "Saved estimate", so the column keeps its width
    /// between states and the station name beside it never shrinks.
    var shortTimingLabel: String {
        if isEnded { return state.timingBasis == .estimated ? "Last estimate" : JourneyTrust.timetable.title }
        if isStale, state.timingBasis == .estimated { return "Saved" }
        return timingLabel
    }

    var timeZone: TimeZone {
        state.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
    }

    var timeZoneText: String {
        guard state.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) != nil else { return "UTC" }
        return timeZone.abbreviation(for: eventDate ?? referenceDate) ?? "UTC"
    }

    var timeText: String? {
        eventDate.map {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.timeStyle = .short
            return formatter.string(from: $0)
        }
    }

    /// The island's glance: the time in the traveller's own 12- or 24-hour style without
    /// AM/PM ("2:25" or "14:25"), "~" for a live estimate. Saved data still shows its time;
    /// the view dims it. Status words replace a time only when there is no time to show.
    var compactText: String {
        if isCancelled { return RunningStatusWords.canceled }
        if isEnded { return "Ended" }
        guard let eventDate else { return "—" }
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour(.defaultDigits(amPM: .omitted)).minute()
        style.calendar = Calendar(identifier: .gregorian)
        let value = eventDate.formatted(style)
        return state.timingBasis == .estimated && !isStale ? "~\(value)" : value
    }

    /// Injected in tests; the traveller's locale otherwise.
    var locale: Locale = .trainTrackerTime

    var platform: String? {
        guard !isCancelled, !isEnded, !isStale, state.phase != .unavailable,
              state.platformBasis != .unavailable, let platform = state.platform else { return nil }
        let trimmed = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Track" at Amtrak stations; content from older servers without the field reads "Platform".
    var platformNoun: String {
        state.platformKind == .track ? "Track" : "Platform"
    }

    /// A new projection verifies this exact call and an actual departure. Old payloads,
    /// stale assignments and the rest of the journey keep the standard ticket treatment.
    var boardingPlatform: String? {
        guard attributes.isRiding == true, state.boardingPlatformSequence == attributes.boardingStopSequence,
              state.phase == .departureSoon, state.platformBasis == .reported, !state.isStopCancelled,
              let eventDate, eventDate > referenceDate, eventDate.timeIntervalSince(referenceDate) <= 1_800,
              let platform else { return nil }
        return platform
    }

    var boardingDepartureLabel: String {
        state.timingBasis == .estimated ? "Estimated departure" : "Timetable departure"
    }

    var platformLabel: String {
        let noun = platformNoun
        let lower = noun.lowercased()
        switch state.platformBasis {
        case .reported:
            if state.platformChanged { return "\(noun) changed" }
            return state.platformSource.map { "\(noun) via \($0)" } ?? "Reported \(lower)"
        case .predicted: return "Likely \(lower)"
        case .scheduled: return "Scheduled \(lower)"
        case .unavailable: return noun
        }
    }

    var evidenceText: String {
        if isEnded { return state.timingBasis == .estimated ? "Last estimate has passed" : "Timetable time has passed" }
        if isCancelled { return "Check the operator’s advice" }
        if isStale { return "\(freshness.text(at: referenceDate, style: .compact)) · Saved times shown" }
        if hasDelay, let delay = state.delayMinutes { return RunningStatusWords.late(delay) }
        if state.platformBasis == .predicted { return "Check station displays" }
        if state.phase == .unavailable { return "Open for journey details" }
        return state.timingBasis == .scheduled ? "From the timetable" : "Provider estimate"
    }

    var actionTitle: String { isStale && !isEnded && !isCancelled ? "Open to refresh" : "Open journey" }

    var accessibilitySummary: String {
        var parts = [attributes.serviceName, phaseTitle, focusLabel, focusName]
        if let timeText {
            parts.append("\(timingLabel) \(timeText), \(timeZoneText)")
            if state.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) == nil {
                parts.append("Station time zone unavailable. Time shown in UTC.")
            }
        }
        if let platform { parts.append("\(platformLabel) \(platform)") }
        parts.append(evidenceText)
        parts.append(actionTitle)
        return parts.joined(separator: ". ")
    }
}
