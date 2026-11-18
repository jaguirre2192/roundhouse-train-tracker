import SwiftUI
import TrainTrackerCore
import WidgetKit

/// Small: one train, one answer. Route codes, the anchor time (departure, or arrival once
/// underway), the status, then where to go and how fresh the times are.
struct NextTrainSmallView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NextTrainEntry

    var body: some View {
        switch entry.display {
        case .empty:
            NextTrainEmptyView(compact: true)
        case let .train(train, following):
            ticket(WidgetTrainPresentation(train: train, at: entry.date), following: following, ended: false)
        case let .ended(train):
            ticket(WidgetTrainPresentation(train: train, at: entry.date), following: nil, ended: true)
        }
    }

    private func ticket(_ presentation: WidgetTrainPresentation, following: WidgetTripSnapshot.Train?, ended: Bool) -> some View {
        let ink = NextTrainInk(renderingMode)
        return VStack(alignment: .leading, spacing: 0) {
            NextTrainRouteRail(presentation: presentation, codeFont: .headline.weight(.bold), stacksNames: true)
            Spacer(minLength: 4)
            // Close to the moment, the answer is how long; further out, it is the time.
            HStack(spacing: 4) {
                Text(presentation.countdownText == nil ? presentation.anchor.rawValue : presentation.countdownLabel)
                if let zone = presentation.anchorZone { Text("· \(zone)") }
            }
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(ink.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            hero(presentation, font: .title.weight(.bold))
                .foregroundStyle(ink.primary)
                .widgetAccentable()
            NextTrainStatusLine(presentation: presentation, showsStruckTime: presentation.countdownText == nil)
            Spacer(minLength: 4)
            Text(detail(presentation, following: following, ended: ended))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            NextTrainTrustLine(presentation: presentation, override: footnoteOverride(ended: ended))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
    }

    /// The countdown when the train is close; otherwise the clock time, as before.
    @ViewBuilder
    private func hero(_ presentation: WidgetTrainPresentation, font: Font) -> some View {
        if let countdown = presentation.countdownText {
            Text(countdown)
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        } else {
            presentation.anchorText(font: font)
        }
    }

    private func detail(_ presentation: WidgetTrainPresentation, following: WidgetTripSnapshot.Train?, ended: Bool) -> String {
        if ended { return "No upcoming trains" }
        switch presentation.phase {
        case .underway:
            guard let stop = presentation.nextStop, let time = presentation.nextStopTimeText else { return presentation.platformText }
            return "Next \(stop.label) \(time)"
        case .arrived:
            guard let following, let next = followingTime(following) else { return "No more trains today" }
            return "Then \(next)"
        case .cancelled:
            return "Check operator advice"
        case .upcoming:
            return presentation.platformText
        }
    }

    private func footnoteOverride(ended: Bool) -> String? {
        if entry.source != .live { return "Sample journey" }
        return ended ? "Journey ended" : nil
    }

    private func followingTime(_ train: WidgetTripSnapshot.Train) -> String? {
        WidgetTrainPresentation(train: train, at: entry.date).anchorTimeText
    }
}

/// Medium: the same anchor, plus the ticket's route rail, a stub of next stop and arrival,
/// and the train after this one.
struct NextTrainMediumView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NextTrainEntry

    var body: some View {
        switch entry.display {
        case .empty:
            NextTrainEmptyView(compact: false)
        case let .train(train, following):
            ticket(WidgetTrainPresentation(train: train, at: entry.date), following: following, ended: false)
        case let .ended(train):
            ticket(WidgetTrainPresentation(train: train, at: entry.date), following: nil, ended: true)
        }
    }

    private func ticket(_ presentation: WidgetTrainPresentation, following: WidgetTripSnapshot.Train?, ended: Bool) -> some View {
        let ink = NextTrainInk(renderingMode)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(TrainTrackerSymbol.train)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ink.route)
                    .accessibilityHidden(true)
                Text(presentation.train.serviceName)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                NextTrainStatusLine(presentation: presentation, showsStruckTime: false)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            NextTrainRouteRail(presentation: presentation)
            Spacer(minLength: 6)
            Rectangle().fill(ink.rail).frame(height: 1).accessibilityHidden(true)
            Spacer(minLength: 6)
            stub(presentation, ink: ink)
            Spacer(minLength: 4)
            footer(presentation, following: following, ended: ended, ink: ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Three equal columns in a two-row grid: labels share one line and values share one text
    /// baseline, so the large anchor time and the smaller track and arrival read as one row.
    /// A missing value keeps its slot as "—".
    private func stub(_ presentation: WidgetTrainPresentation, ink: NextTrainInk) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow(alignment: .bottom) {
                stubLabel(anchorLabel(presentation), ink: ink)
                stubLabel(middleLabel(presentation), ink: ink)
                stubLabel(lastLabel(presentation), ink: ink)
            }
            GridRow(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let countdown = presentation.countdownText {
                            Text(countdown)
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .contentTransition(.numericText())
                        } else {
                            presentation.anchorText(font: .title2.weight(.bold))
                        }
                    }
                    .foregroundStyle(ink.primary)
                    .widgetAccentable()
                    if presentation.countdownText == nil, let struck = presentation.struckTimetableText {
                        Text(struck)
                            .font(.caption2)
                            .monospacedDigit()
                            .strikethrough(true, color: ink.secondary)
                            .foregroundStyle(ink.secondary)
                            .accessibilityLabel("timetable \(struck)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                middleValue(presentation, ink: ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                lastValue(presentation, ink: ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stubLabel(_ text: String, ink: NextTrainInk) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(ink.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }

    private func anchorLabel(_ presentation: WidgetTrainPresentation) -> String {
        let label = presentation.countdownText == nil ? presentation.anchor.rawValue : presentation.countdownLabel
        guard let zone = presentation.anchorZone else { return label }
        return "\(label) · \(zone)"
    }

    private func middleLabel(_ presentation: WidgetTrainPresentation) -> String {
        switch presentation.phase {
        case .underway: "Next stop"
        case .arrived: "Departed"
        case .upcoming, .cancelled: presentation.platformNoun
        }
    }

    private func lastLabel(_ presentation: WidgetTrainPresentation) -> String {
        switch presentation.phase {
        case .upcoming, .cancelled: "Arrives"
        case .underway, .arrived: presentation.platformNoun
        }
    }

    @ViewBuilder
    private func middleValue(_ presentation: WidgetTrainPresentation, ink: NextTrainInk) -> some View {
        switch presentation.phase {
        case .underway:
            VStack(alignment: .leading, spacing: 0) {
                value(presentation.nextStop?.label ?? "—", ink: ink)
                Text(presentation.nextStopTimeText ?? "—")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ink.secondary)
            }
        case .arrived:
            value(departureText(presentation), ink: ink)
        case .upcoming, .cancelled:
            value(presentation.platformValue ?? "—", ink: ink)
        }
    }

    @ViewBuilder
    private func lastValue(_ presentation: WidgetTrainPresentation, ink: NextTrainInk) -> some View {
        switch presentation.phase {
        case .upcoming, .cancelled:
            value(presentation.arrivalTimeText, ink: ink)
                .strikethrough(presentation.status == .cancelled)
        case .underway, .arrived:
            value(presentation.platformValue ?? "—", ink: ink)
        }
    }

    private func value(_ text: String, ink: NextTrainInk) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(ink.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func departureText(_ presentation: WidgetTrainPresentation) -> String {
        guard let departure = presentation.train.departure else { return "—" }
        return presentation.clock.time(departure.effective, timeZoneIdentifier: presentation.train.boarding?.timeZoneIdentifier)
    }

    @ViewBuilder
    private func footer(
        _ presentation: WidgetTrainPresentation, following: WidgetTripSnapshot.Train?, ended: Bool, ink: NextTrainInk
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let following, let url = following.deepLinkURL {
                Link(destination: url) { followingText(following, ink: ink) }
            } else {
                Text(ended ? "No upcoming trains" : "No later train tracked")
                    .foregroundStyle(ink.secondary)
            }
            Spacer(minLength: 4)
            NextTrainTrustLine(
                presentation: presentation,
                override: entry.source == .live ? (ended ? "Journey ended" : nil) : "Sample journey"
            )
            .fixedSize()
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func followingText(_ train: WidgetTripSnapshot.Train, ink: NextTrainInk) -> some View {
        let presentation = WidgetTrainPresentation(train: train, at: entry.date)
        return HStack(spacing: 4) {
            Text("Then").foregroundStyle(ink.secondary)
            Text("\(presentation.train.serviceName) · \(presentation.anchorTimeText)")
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(ink.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the following train")
    }
}

/// No tracked trains: one line, and the widget opens Add Journey.
struct NextTrainEmptyView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let compact: Bool

    var body: some View {
        let ink = NextTrainInk(renderingMode)
        VStack(alignment: .leading, spacing: 4) {
            Image(TrainTrackerSymbol.train)
                .font(.title2.weight(.semibold))
                .foregroundStyle(ink.route)
                .widgetAccentable()
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            Text("No trains tracked")
                .font(.headline)
                .foregroundStyle(ink.primary)
            if !compact {
                Text("Add a journey and your next train appears here.")
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
            }
            Spacer(minLength: 4)
            Label("Add Journey", systemImage: "plus.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink.primary)
                .widgetAccentable()
        }
        .lineLimit(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Add Journey")
    }
}
