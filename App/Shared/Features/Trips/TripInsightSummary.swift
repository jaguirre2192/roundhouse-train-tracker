import SwiftUI
import TrainTrackerCore

/// The status as a headline with the next step as a sentence, under the ticket on My Trips and
/// on the journey screen. Every string comes from the presentation the ticket itself uses, so
/// the headline never claims more than the ticket could.
struct TripInsightHeadline: View {
    let presentation: ActiveTripCardPresentation
    var timeZoneIdentifier: (StopTime) -> String? = { _ in nil }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
            Text(presentation.status.headline)
                .font(.title.weight(.bold))
                .foregroundStyle(Color.ttTextPrimary)
                .contentTransition(.numericText())
                .accessibilityAddTraits(.isHeader)
            Text(sentence)
                .font(.body)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy, value: presentation.status.headline)
    }

    private var sentence: String {
        let progress = presentation.effectiveProgress
        if progress.phase == .ended, !presentation.trip.isCancelled, let last = progress.stops.last,
           let arrival = StopTimelineTimePresentation(stop: last, event: .arrival, timeZoneIdentifier: timeZoneIdentifier(last)).timeText {
            // Says what is known, without claiming the arrival itself was reported.
            return progress.timingBasis == .estimated
                ? "The last estimate into \(last.station.displayName) was \(arrival)."
                : "The timetable arrival at \(last.station.displayName) was \(arrival)."
        }
        guard progress.phase != .ended, !presentation.trip.isCancelled,
              let stop = presentation.guidanceStop else { return presentation.nextStopValue }

        let name = stop.station.displayName
        let lead: String
        if presentation.isBeforeBoarding { lead = "Board at \(name)" }
        else if progress.evidence.observedFocusStopID == stop.id { lead = "\(name) is next" }
        else { lead = "\(name) is next by \(progress.timingBasis == .estimated ? "the last estimate" : "the timetable")" }
        let time = StopTimelineTimePresentation(
            stop: stop, event: presentation.isBeforeBoarding ? .departure : .arrival,
            timeZoneIdentifier: timeZoneIdentifier(stop)
        ).timeText
        var parts = [time.map { "\(lead) at \($0)." } ?? "\(lead)."]

        if let last = progress.stops.last, last.id != stop.id,
           let arrival = StopTimelineTimePresentation(stop: last, event: .arrival, timeZoneIdentifier: timeZoneIdentifier(last)).timeText {
            parts.append(progress.timingBasis == .estimated
                ? "Arrival at \(last.station.displayName) is estimated for \(arrival)."
                : "Arrival at \(last.station.displayName) is \(arrival) by the timetable.")
        }
        return parts.joined(separator: " ")
    }
}

/// One of the four facts under the headline. Each opens the place that answers it.
enum TripFact: String, CaseIterable, Identifiable {
    case nextStop, platform, arrival, status

    var id: String { rawValue }

    var accessibilityHint: String {
        switch self {
        case .nextStop: "Opens the journey and its stops"
        case .platform: "Opens the station in Maps"
        case .arrival: "Opens the live map"
        case .status: "Opens the journey"
        }
    }
}

/// The focused train's facts as tappable pairs: a label, a large value and a note. Values roll
/// when live data changes them.
struct TripFactGrid: View {
    let presentation: ActiveTripCardPresentation
    var timeZoneIdentifier: (StopTime) -> String? = { _ in nil }
    let select: (TripFact) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Cell: Identifiable {
        let fact: TripFact
        let label: String
        let value: String
        var valueColor: Color = .ttTextPrimary
        var note: String?
        var id: String { fact.rawValue }
    }

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        let cells = cells
        let rows = stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
        Grid(alignment: .topLeading, horizontalSpacing: TrainTrackerSpacing.space20, verticalSpacing: TrainTrackerSpacing.space8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { cell in
                        Button { select(cell.fact) } label: { label(for: cell) }
                            .buttonStyle(TripFactButtonStyle(reduceMotion: reduceMotion))
                            .accessibilityHint(cell.fact.accessibilityHint)
                            .accessibilityIdentifier("tripFact-\(cell.fact.rawValue)")
                    }
                }
            }
        }
        // The press highlight extends past the text, which stays on the page's leading edge.
        .padding(.horizontal, -TripFactButtonStyle.inset)
    }

    private func label(for cell: Cell) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            // A quiet label: the whole cell presses, so the label need not dress as a link.
            Text(cell.label)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
            Text(cell.value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(cell.valueColor)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: cell.value)
            if let note = cell.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.ttTextSecondary)
                    .monospacedDigit()
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
    }

    private var cells: [Cell] {
        let progress = presentation.effectiveProgress
        let freshness = TripFreshness(
            lastSuccessfulCheck: presentation.lastSuccessfulCheck, lastRefreshFailed: presentation.lastRefreshFailed
        )
        // Saved data never takes an alarm colour, matching the ticket's badge.
        let statusIsCurrent = !LiveLineTicketPresentation.claimsLiveTiming(presentation.status.kind) || freshness.isConfirmed
        let platformMissing = presentation.platformValue == "Not in feed"
        let arrival = progress.stops.last.flatMap {
            StopTimelineTimePresentation(stop: $0, event: .arrival, timeZoneIdentifier: timeZoneIdentifier($0)).timeText
        }
        let nextTime = presentation.guidanceStop.flatMap {
            StopTimelineTimePresentation(
                stop: $0, event: presentation.isBeforeBoarding ? .departure : .arrival,
                timeZoneIdentifier: timeZoneIdentifier($0)
            ).timeText
        }

        return [
            Cell(fact: .nextStop, label: TripObservationLabels.focus(progress), value: presentation.nextStopValue, note: nextTime),
            Cell(
                fact: .platform, label: presentation.platformLabel, value: presentation.platformValue,
                valueColor: platformMissing ? .ttTextSecondary : presentation.platformValueColor,
                note: platformMissing ? "Check station boards" : nil
            ),
            Cell(
                fact: .arrival, label: TripObservationLabels.arrival(progress), value: arrival ?? TicketStubField.unavailableValue,
                valueColor: arrival == nil ? .ttTextSecondary : .ttTextPrimary,
                note: presentation.destinationName
            ),
            Cell(
                fact: .status, label: presentation.detailStatusLabel, value: presentation.detailStatusValue,
                valueColor: presentation.status.kind.isDisruption && statusIsCurrent ? presentation.status.color : .ttTextPrimary,
                note: freshness.text(at: presentation.referenceDate, style: .compact)
            ),
        ]
    }
}

/// A fact answers a press with a soft plate and a slight settle, then releases.
private struct TripFactButtonStyle: ButtonStyle {
    static let inset = TrainTrackerSpacing.space8
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(Self.inset)
            .background(
                Color.ttBackgroundElevated.opacity(configuration.isPressed ? 0.7 : 0),
                in: RoundedRectangle(cornerRadius: TrainTrackerRadius.status, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: TrainTrackerRadius.status, style: .continuous))
    }
}
