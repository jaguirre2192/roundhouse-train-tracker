import SwiftUI
import TrainTrackerCore

/// One train's glance, filling the page. On the smallest watches a long state tightens
/// before anything is cut, and it scrolls only when the rider's text size needs it.
struct WatchTrainPage: View {
    @Environment(WatchStore.self) private var store
    let train: WidgetTripSnapshot.Train
    let date: Date
    /// Every train has finished; this one stays on screen, marked as ended.
    var hasEnded = false

    var body: some View {
        let presentation = WidgetTrainPresentation(train: train, at: date)
        let offersWake = !hasEnded && WatchWakePage.isOffered(for: train, at: date)
        let wakeLead = offersWake ? store.wakeState(for: train.id).armedLead : nil
        GeometryReader { proxy in
            let glance = { (density: WatchTrainGlance.Density) in
                WatchTrainGlance(
                    presentation: presentation, hasEnded: hasEnded, wakeLead: wakeLead,
                    width: proxy.size.width, density: density
                )
                .scenePadding(.horizontal)
            }
            ViewThatFits(in: .vertical) {
                glance(.regular)
                glance(.snug)
                glance(.compact)
                ScrollView { glance(.compact) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The page after a train's glance: the wake switch for the stop the rider gets off at.
struct WatchWakePage: View {
    @Environment(WatchStore.self) private var store
    let train: WidgetTripSnapshot.Train

    var body: some View {
        ScrollView {
            WatchWakeControl(train: train, state: store.wakeState(for: train.id))
                .scenePadding(.horizontal)
        }
    }

    /// The phone arms an alert only for a stop still ahead of a running or upcoming train.
    static func isOffered(for train: WidgetTripSnapshot.Train, at date: Date) -> Bool {
        switch WidgetTrainPhase(train: train, at: date) {
        case .upcoming, .underway: true
        case .arrived, .cancelled: false
        }
    }
}

/// The glance: which train, where it runs, and one large answer to "how long?".
///
/// Reading order top to bottom: the train, the route, what the number counts to, the number,
/// how the train is running, and last, quietly, how current all of that is.
struct WatchTrainGlance: View {
    let presentation: WidgetTrainPresentation
    let hasEnded: Bool
    /// Minutes of lead when the phone has confirmed a wake alert for this train.
    let wakeLead: Int?
    let width: CGFloat
    var density = Density.regular

    /// How much air the glance takes. A long state steps down gently, so the hero never
    /// shrinks more than the screen requires; compact is for the smallest watches.
    enum Density {
        case regular
        case snug
        case compact

        var heroScale: CGFloat {
            switch self {
            case .regular: 1
            case .snug: 0.92
            case .compact: 0.82
            }
        }

        var gap: CGFloat {
            switch self {
            case .regular: 4
            case .snug: 2
            case .compact: 1
            }
        }
    }

    /// Follows the rider's text size; the hero's own size comes from the screen's width.
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    private var heroSize: CGFloat {
        Self.heroSize(forWidth: width) * typeScale * density.heroScale
    }

    var body: some View {
        let trust = presentation.relayedTrust
        VStack(alignment: .leading, spacing: 0) {
            identity
            WatchRouteRail(presentation: presentation, isLive: trust == .live)
                .padding(.top, density.gap / 2)
            Spacer(minLength: density.gap)
            Text(label)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(hero)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.default, value: heroText)
                // The line box of a large font is taller than its digits; close it up.
                .padding(.top, -heroSize * 0.15)
                .padding(.bottom, -heroSize * 0.12)
                // Large digits carry side bearing, a fixed-width 1 most of all; pull them onto
                // the text's left edge.
                .padding(.leading, -heroSize * (heroText.hasPrefix("1") ? 0.1 : 0.045))
            if let status = statusLine(trust) {
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: density.gap)
            trustLine(trust)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(trust))
    }

    // MARK: The train

    private var identity: some View {
        HStack(spacing: 5) {
            WatchTrainName(name: presentation.train.serviceName)
            Spacer(minLength: 4)
            if wakeLead != nil {
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: The answer

    /// What the hero counts to, with the clock time: "Leaves 6:27 PM", "Arrives 7:52 PM". When
    /// the hero is the clock time itself, only the verb, and the day when it is not today.
    private var label: String {
        if hasEnded { return presentation.anchor.rawValue }
        if presentation.isArrivalUnconfirmed {
            return presentation.anchor == .departs ? "Timetable departure" : "Timetable arrival"
        }
        if presentation.countdownText != nil {
            return [presentation.countdownLabel, presentation.anchorZone].compactMap(\.self).joined(separator: " ")
        }
        var parts = [presentation.anchor.rawValue]
        if let day = dayQualifier { parts.append(day) }
        if let zone = presentation.anchorZone { parts.append("· \(zone)") }
        return parts.joined(separator: " ")
    }

    private var dayQualifier: String? {
        guard let anchor = presentation.anchorDate, presentation.phase != .arrived else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(anchor, inSameDayAs: presentation.date) { return nil }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: presentation.date),
           calendar.isDate(anchor, inSameDayAs: tomorrow) { return "tomorrow" }
        return anchor.formatted(.dateTime.weekday(.abbreviated))
    }

    /// The countdown while the moment is close, otherwise the clock time.
    private var heroText: String {
        presentation.isArrivalUnconfirmed ? presentation.anchorTimeText
            : presentation.countdownText ?? presentation.anchorTimeText
    }

    /// Digits large and rounded; the unit ("min", "h", "PM") smaller and quieter beside them.
    private var hero: AttributedString {
        let isVoid = presentation.status == .cancelled
        // A canceled time is struck through whole, so it is set at one size.
        let size = heroSize * (isVoid ? 0.72 : 1)
        let digits = Font.system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        let unit = isVoid ? digits : Font.system(size: size * 0.44, weight: .semibold, design: .rounded)
        var result = AttributedString()
        // Clock times separate the day period with a narrow no-break space, not a plain one.
        for (index, token) in heroText.split(whereSeparator: \.isWhitespace).enumerated() {
            if index > 0 {
                var space = AttributedString(" ")
                space.font = unit
                if isVoid { space.strikethroughStyle = .single }
                result += space
            }
            let isUnit = token != "Now" && token.allSatisfy(\.isLetter)
            var run = AttributedString(String(token))
            run.font = isUnit ? unit : digits
            run.foregroundColor = isUnit || isVoid ? .secondary : .primary
            if isVoid { run.strikethroughStyle = .single }
            result += run
        }
        return result
    }

    private static func heroSize(forWidth width: CGFloat) -> CGFloat {
        // Three tenths of the screen's width: 48 pt on a 40 mm watch, 58 pt from 46 mm up.
        min(max(width * 0.3, 44), 58)
    }

    // MARK: How it is running

    /// Plain words for how the train is running. Nothing is claimed when only the timetable
    /// is known; the trust line says "Timetable".
    private var runningText: String? {
        if presentation.isArrivalUnconfirmed { return presentation.statusText }
        return switch presentation.status {
        case .onTime: RunningStatusWords.onTime
        case let .delayed(minutes): RunningStatusWords.late(minutes)
        case .cancelled: RunningStatusWords.canceled
        case .arrived, .scheduled: nil
        }
    }

    /// Where to stand: "Track 7".
    private var platformText: String? {
        presentation.platformValue.map { "\(presentation.platformNoun) \($0)" }
    }

    private var statusText: String? {
        let parts = [runningText, platformText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How it is running, colored when that needs attention, then the platform in plain ink.
    private func statusLine(_ trust: JourneyTrust) -> AttributedString? {
        guard statusText != nil else { return nil }
        var line = AttributedString()
        if let runningText {
            var running = AttributedString(runningText)
            running.foregroundColor = statusStyle(trust)
            line += running
        }
        if let platformText {
            var platform = AttributedString(runningText == nil ? platformText : " · \(platformText)")
            platform.foregroundColor = trust.isConfirmed ? .primary : .secondary
            line += platform
        }
        return line
    }

    /// Color only for what needs attention, and only when the times were checked recently:
    /// saved times never raise an alarm.
    private func statusStyle(_ trust: JourneyTrust) -> Color {
        guard trust.isConfirmed else { return .secondary }
        switch presentation.status {
        case .delayed: return Color(.delayedOnInk)
        case .cancelled: return Color(.cancelledOnInk)
        case .onTime, .scheduled, .arrived: return .primary
        }
    }

    private var detail: String? {
        if hasEnded { return nil }
        switch presentation.phase {
        case .cancelled:
            return "Check operator advice"
        case .underway:
            // The rider's own stop is the hero; an earlier call is worth one quiet line.
            guard let stop = presentation.nextStop, stop != presentation.train.alighting,
                  let time = presentation.nextStopTimeText else { return nil }
            return "\(presentation.nextStopLabel) \(stop.label) \(time)"
        case .upcoming, .arrived:
            return nil
        }
    }

    // MARK: How current it is

    private func trustLine(_ trust: JourneyTrust) -> some View {
        HStack(spacing: 4) {
            if !hasEnded, trust == .live {
                Circle()
                    .fill(Color(.liveOnInk))
                    .frame(width: 6, height: 6)
            }
            Text(hasEnded ? RunningStatusWords.ended : presentation.compactTrustLine(trust))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // On watchOS footnote is the smallest text style, below the captions.
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func accessibilityLabel(_ trust: JourneyTrust) -> String {
        var parts = [
            presentation.train.serviceName,
            "\(presentation.train.boarding?.name ?? presentation.originLabel) to \(presentation.train.alighting?.name ?? presentation.destinationLabel)",
        ]
        if let countdown = presentation.countdownText, !presentation.isArrivalUnconfirmed {
            parts.append("\(presentation.countdownLabel), in \(Self.spoken(countdown))")
        } else {
            parts.append("\(label) \(presentation.anchorTimeText)")
        }
        if let statusText { parts.append(statusText) }
        if let detail { parts.append(detail) }
        if let wakeLead { parts.append("Wake alert on, \(wakeLead) minutes before your stop") }
        parts.append(hasEnded ? RunningStatusWords.ended : presentation.compactTrustLine(trust))
        return parts.joined(separator: ". ")
    }

    /// "25 min" as "25 minutes", "1 h 05" as "1 hour 5 minutes".
    private static func spoken(_ countdown: String) -> String {
        let tokens = countdown.split(separator: " ")
        if tokens.count == 3, let hours = Int(tokens[0]), let minutes = Int(tokens[2]) {
            return "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        if tokens.count == 2, let minutes = Int(tokens[0]) { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return countdown
    }
}

/// Which train a page is about: the app's own train symbol in brand teal, then its name.
struct WatchTrainName: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(TrainTrackerSymbol.train)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.footnote.weight(.semibold))
    }
}

/// The route as the app draws it everywhere: both ends joined by a rail. Underway, the part
/// supported by confirmed passage is teal; the clock alone cannot complete the rail.
struct WatchRouteRail: View {
    let presentation: WidgetTrainPresentation
    let isLive: Bool

    var body: some View {
        if presentation.hasCodes {
            HStack(spacing: 8) {
                Text(presentation.originLabel)
                rail
                Text(presentation.destinationLabel)
            }
            .font(.title3.weight(.semibold))
            .lineLimit(1)
        } else {
            // Station names are too long to share a line with a rail.
            Text("\(presentation.originLabel) → \(presentation.destinationLabel)")
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private var rail: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = progressFraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 2)
                Capsule().fill(Color(.routeOnInk)).frame(width: width * progress, height: 2)
                Circle().fill(Color(.routeOnInk)).frame(width: 6, height: 6)
                Circle().strokeBorder(progress >= 1 ? Color(.routeOnInk) : .white.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .offset(x: width - 7)
                if case .underway = presentation.phase {
                    Circle()
                        .fill(isLive ? Color(.liveOnInk) : .white)
                        .frame(width: 9, height: 9)
                        .overlay { Circle().stroke(.black, lineWidth: 2) }
                        .offset(x: min(max(8, width * progress - 4.5), width - 18))
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 12)
        .frame(minWidth: 24)
    }

    private var progressFraction: Double {
        switch presentation.phase {
        case .underway: presentation.legProgress
        case .arrived: 1
        case .upcoming, .cancelled: 0
        }
    }
}

extension WatchStore.WakeState {
    /// The lead the phone has confirmed; nil while off, asked for, or refused.
    var armedLead: Int? {
        if case let .armed(lead) = self { return lead }
        return nil
    }
}
