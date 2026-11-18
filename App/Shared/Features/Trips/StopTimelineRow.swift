import SwiftUI
import TrainTrackerCore

/// Where a stop sits relative to the train: passed, the next stop, or still to come.
enum LiveMarkerState: Equatable {
    case live
    case upcoming
    case passed
}

struct StopTimelineRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let stop: StopTime
    let isNext: Bool
    let isLast: Bool
    var isFirst = false
    let timeZoneIdentifier: String?
    let isEarlier: Bool?
    let stateOverride: String?
    let referenceDate: Date
    /// False for a stop whose time has gone by with nothing reporting the train there. It is
    /// then drawn as due by the timetable, not as reached.
    var isReachConfirmed = true
    let nextStopRole: String
    var compareClocks: (() -> Void)?
    var selectOnMap: (() -> Void)?
    var mapSelected = false

    init(
        stop: StopTime, isNext: Bool, isLast: Bool, isFirst: Bool = false,
        timeZoneIdentifier: String? = nil,
        isEarlier: Bool? = nil, stateOverride: String? = nil,
        referenceDate: Date = .now, isReachConfirmed: Bool = true, nextStopRole: String = "Next stop",
        compareClocks: (() -> Void)? = nil, selectOnMap: (() -> Void)? = nil, mapSelected: Bool = false
    ) {
        self.nextStopRole = nextStopRole
        self.compareClocks = compareClocks
        self.selectOnMap = selectOnMap
        self.mapSelected = mapSelected
        self.isReachConfirmed = isReachConfirmed
        self.stop = stop
        self.isNext = isNext
        self.isLast = isLast
        self.isFirst = isFirst
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isEarlier = isEarlier
        self.stateOverride = stateOverride
        self.referenceDate = referenceDate
    }

    var body: some View {
        if let compareClocks {
            StopTimelineColumns {
                Button(action: compareClocks) {
                    timeColumn
                        .frame(minHeight: 44, alignment: .top)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Compare station clocks at \(stop.station.displayName)")
                .accessibilityHint("Shows this time in both station time zones")
                .accessibilityIdentifier("routeClockTime-\(stop.id)")
            } rail: {
                timelineRail
            } detail: {
                VStack(alignment: .leading, spacing: 0) {
                    if let selectOnMap {
                        Button(action: selectOnMap) { stopContent.contentShape(.rect) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilitySummary)
                            .accessibilityHint("Shows this stop on the map")
                            .accessibilityIdentifier("routeStop-\(stop.id)")
                            .accessibilityAddTraits(mapSelected ? .isSelected : [])
                    } else {
                        stopContent.accessibilityElement(children: .ignore).accessibilityLabel(accessibilitySummary)
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        Button("Compare station clocks", action: compareClocks)
                            .font(.footnote.weight(.medium))
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("routeClockTime-\(stop.id)")
                    }
                }
                .padding(.bottom, TrainTrackerSpacing.space16)
            }
            .frame(minHeight: 52, alignment: .top)
        } else {
            summaryRow
        }
    }

    @ViewBuilder
    private var stopContent: some View {
        if dynamicTypeSize.isAccessibilitySize { accessibilityContent }
        else { standardContent }
    }

    private var summaryRow: some View {
        StopTimelineColumns {
            timeColumn
        } rail: {
            timelineRail
        } detail: {
            stopContent.padding(.bottom, TrainTrackerSpacing.space16)
        }
        .frame(minHeight: 52, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private static let railWidth: CGFloat = 3
    /// The dot's centre sits this far below the row top, level with the first text line.
    private static let dotCenterY: CGFloat = 11

    /// The time the train leaves (or reaches the destination), with the timetable time struck
    /// through beneath it when the estimate runs five or more minutes late.
    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: TrainTrackerSpacing.space2) {
            Text(timePresentation.timeText ?? "—")
                .font(isNext ? .headline.weight(.bold) : .body)
                .monospacedDigit()
                .underline(compareClocks != nil, pattern: .dot, color: .ttActionTint)
                .foregroundStyle(compareClocks == nil ? rowTextColor : Color.ttActionTint)
            if let scheduledTimeText {
                Text(scheduledTimeText)
                    .font(.caption2)
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            stationHeading

            // One quiet line under the name: what this stop is to the journey, how late, and
            // the track. No chips and no boxes; weight and color carry what matters.
            detailLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stationName: some View {
        Text(stop.station.displayName)
            .font(isNext ? .headline.weight(.bold) : .body)
            .foregroundStyle(rowTextColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var stationHeading: some View {
        if isNext, !stop.isCancelled, let platform = officialPlatformText {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                    stationName.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    nextPlatformLabel(platform)
                }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    stationName
                    nextPlatformLabel(platform)
                }
            }
        } else {
            stationName
        }
    }

    private func nextPlatformLabel(_ platform: String) -> some View {
        Text(platform)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(platformGuidance.isOfficialChange ? Color.ttStatusDelayed : .ttTextBrand)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var detailLine: some View {
        if stop.isCancelled {
            stateLabel
        } else {
            let parts = detailParts
            if !parts.isEmpty {
                // One line while it fits; otherwise each fact on its own line, so a line never
                // ends on a stray separator.
                ViewThatFits(in: .horizontal) {
                    parts.dropFirst().reduce(parts[0]) { $0 + Text("  ·  ").foregroundStyle(Color.ttTextSecondary) + $1 }
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { $0.element }
                    }
                }
                .font(.footnote)
            }
        }
    }

    private var detailParts: [Text] {
        var parts: [Text] = []
        if isNext {
            parts.append(Text(focusDescription).foregroundStyle(Color.ttTextPrimary))
        } else if let stateOverride {
            parts.append(Text(stateOverride).foregroundStyle(Color.ttTextSecondary))
        }
        if stopIsEarlier, !isReachConfirmed {
            parts.append(Text("By timetable").foregroundStyle(Color.ttTextSecondary))
        }
        if let delay = timePresentation.delayMinutes, delay >= 5 {
            parts.append(Text(RunningStatusWords.late(delay))
                .fontWeight(isNext ? .semibold : .regular)
                .foregroundStyle(isConfirmedEarlier ? Color.ttTextSecondary : .ttStatusDelayed))
        }
        if let platform = officialPlatformText {
            if !isNext {
                parts.append(Text(platform).foregroundStyle(Color.ttTextSecondary))
            }
        } else if let platformText {
            parts.append(Text(platformText).foregroundStyle(platformColor))
        }
        return parts
    }

    private var focusDescription: String {
        let isBoarding = isFirst
        let event = isBoarding ? timePresentation.date
            : stop.expectedArrival ?? stop.scheduledArrival
        let role = isBoarding ? "Departure" : nextStopRole
        guard let event, event >= referenceDate else { return role }
        let away = JourneyPeekStrip.timeAway(until: event, from: referenceDate)
        return away == "Now" ? "\(role) · Due now" : "\(role) in \(away)"
    }

    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            stationName

            stateLabel

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                timeLabel
                punctualityLabel
            }

            if let platformText {
                Text(platformText)
                    .font(.subheadline.weight(isNext ? .semibold : .regular))
                    .foregroundStyle(platformColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stateLabel: some View {
        if stop.isCancelled {
            Label(RunningStatusWords.canceled, systemImage: "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ttStatusCancelled)
        } else if stopIsEarlier, !isReachConfirmed {
            Text("By timetable")
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
        } else if let stateOverride {
            Text(stateOverride)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ttTextSecondary)
        } else if isNext {
            Text(nextStopRole)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)
        }
    }

    @ViewBuilder
    private var timeLabel: some View {
        if let timeText = timePresentation.timeText {
            Text(timeText)
                .font(isNext ? .headline.weight(.bold).monospacedDigit() : .body.monospacedDigit())
                .foregroundStyle(rowTextColor)
        } else {
            Text("Time unavailable")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }
    }

    @ViewBuilder
    private var punctualityLabel: some View {
        if !stop.isCancelled {
            if let delay = timePresentation.delayMinutes, delay >= 5 {
                Text("\(eventTitle) · \(RunningStatusWords.late(delay))")
                    .font(.caption.weight(isNext ? .semibold : .regular))
                    .foregroundStyle(isConfirmedEarlier ? Color.ttTextSecondary : .ttStatusDelayed)
            } else {
                Text(hasEstimate ? "Est. \(eventNoun)" : "Sched. \(eventNoun)")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
    }

    private var scheduledTimeText: String? {
        guard !stop.isCancelled, let delay = timePresentation.delayMinutes, delay >= 5 else { return nil }
        let scheduled = eventNoun == "arrival" ? stop.scheduledArrival : stop.scheduledDeparture
        guard let scheduled else { return nil }
        return JourneyPlanDateTimePresentation.time(
            scheduled, timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier
        )
    }

    /// Plain assignment text; predictions keep their full qualification in the detail line.
    private var officialPlatformText: String? {
        if case let .official(platform, _, _) = platformGuidance {
            return "\(stop.platformNoun) \(platform)"
        }
        return nil
    }

    /// A 3 pt rail centred on the dot: the half above belongs to the segment arriving here,
    /// the half below to the segment leaving, so adjacent rows join without a seam.
    private var timelineRail: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : incomingRailColor)
                    .frame(width: Self.railWidth, height: Self.dotCenterY)
                Rectangle()
                    .fill(isLast ? Color.clear : outgoingRailColor)
                    .frame(width: Self.railWidth)
                    .frame(maxHeight: .infinity)
            }
            timelineDot
                .frame(width: Self.dotCenterY * 2, height: Self.dotCenterY * 2)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var timelineDot: some View {
        switch markerState {
        case .passed:
            if isReachConfirmed {
                Circle().fill(Color.ttRouteActive).frame(width: 11, height: 11)
            } else {
                // Due by the timetable; nothing reports the train here.
                Circle()
                    .fill(Color.ttBackgroundCanvas)
                    .overlay { Circle().strokeBorder(Color.ttRouteActive, lineWidth: 2) }
                    .frame(width: 11, height: 11)
            }
        case .live:
            Circle()
                .fill(Color.ttBackgroundCanvas)
                .overlay { Circle().strokeBorder(Color.ttTextPrimary, lineWidth: 3.5) }
                .frame(width: 16, height: 16)
        case .upcoming:
            if isLast && !stop.isCancelled {
                Circle()
                    .fill(Color.ttBackgroundCanvas)
                    .overlay { Circle().strokeBorder(Color.ttTextBrand, lineWidth: 3.5) }
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .fill(Color.ttBackgroundCanvas)
                    .overlay { Circle().strokeBorder(Color.ttTextSecondary.opacity(0.7), lineWidth: 2) }
                    .frame(width: 11, height: 11)
            }
        }
    }

    private var incomingRailColor: Color {
        (stopIsEarlier && isReachConfirmed) || (isNext && isReachConfirmed) ? .ttRouteActive : .ttRoutePassed
    }

    private var outgoingRailColor: Color {
        stopIsEarlier && isReachConfirmed ? .ttRouteActive : .ttRoutePassed
    }

    private var markerState: LiveMarkerState {
        if stop.isCancelled { return .upcoming }
        if isNext { return .live }
        if stopIsEarlier { return .passed }
        return .upcoming
    }

    private var timePresentation: StopTimelineTimePresentation {
        StopTimelineTimePresentation(
            stop: stop, event: isLast ? .arrival : .departure,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private var accessibilitySummary: String {
        var parts = ["\(stopState), \(stop.station.displayName)"]

        if let timeText = timePresentation.timeText {
            parts.append("\(hasEstimate ? "estimated" : "timetable") \(eventNoun) at \(timeText)")
        } else {
            parts.append("time unavailable")
        }

        if case .unavailable = platformGuidance {
            // Keep unavailable platform data out of an already dense stop summary.
        } else {
            parts.append(platformGuidance.isPredicted
                ? "Roundhouse prediction. \(stop.platformSummary(at: referenceDate))"
                : stop.platformSummary(at: referenceDate))
        }

        if !stop.isCancelled {
            if let delay = timePresentation.delayMinutes, delay >= 5 {
                parts.append("\(delay) minutes late")
            }
        }

        return parts.joined(separator: ", ")
    }

    private var stopState: String {
        if stop.isCancelled { return "Canceled stop" }
        if stopIsEarlier, !isReachConfirmed { return "Due earlier by the timetable, not reported" }
        if let stateOverride { return stateOverride }
        if isNext { return nextStopRole }
        if stopIsEarlier { return "Earlier stop" }
        return "Upcoming stop"
    }

    private var platformGuidance: PlatformGuidance {
        stop.platformGuidance(at: referenceDate)
    }

    private var stopIsEarlier: Bool { isEarlier ?? stop.isPassed }
    /// Elapsed timetable rows keep normal emphasis and their explicit qualification. Only
    /// evidence-confirmed earlier stops recede as completed parts of the route.
    private var isConfirmedEarlier: Bool { stopIsEarlier && isReachConfirmed && !stop.isCancelled }
    private var rowTextColor: Color { isConfirmedEarlier ? .ttTextSecondary : .ttTextPrimary }
    /// Intermediate rows list departures and the destination row lists its arrival, so every
    /// time says which it is; the next-step card above shows the next stop's arrival.
    private var eventNoun: String { timePresentation.eventNoun ?? (isLast ? "arrival" : "departure") }
    private var eventTitle: String { eventNoun == "arrival" ? "Arrival" : "Departure" }
    private var hasEstimate: Bool { timePresentation.timingBasis == .estimated }

    private var platformText: String? {
        guard !stop.isCancelled else { return nil }
        switch platformGuidance {
        case .unavailable: return nil
        case .official:
            return stop.platformSummary(at: referenceDate)
        case .likelyPlatform, .positioning: return platformGuidance.summaryText(noun: stop.platformNoun, source: stop.platformSource)
        }
    }

    private var platformColor: Color {
        if isConfirmedEarlier { return .ttTextSecondary }
        if platformGuidance.isOfficialChange { return .ttStatusDelayed }
        if isNext, case .official = platformGuidance { return .ttTextBrand }
        return platformGuidance.isPredicted ? .ttActionLive : .ttTextSecondary
    }
}
