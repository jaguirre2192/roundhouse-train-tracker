import SwiftUI
import TrainTrackerCore
import WidgetKit

// Lock Screen accessories render vibrantly: content stays at full opacity and hierarchy comes
// from the system's primary and secondary styles, never translucent white.

/// "NYP 6:20 · +7 min" beside the clock.
struct NextTrainInlineView: View {
    let entry: NextTrainEntry

    var body: some View {
        ViewThatFits {
            Label { Text(text) } icon: { Image(ttSymbol: symbol) }
            Text(text)
        }
        .monospacedDigit()
    }

    private var text: String {
        switch entry.display {
        case .empty: "No trains tracked"
        case let .train(train, _): WidgetTrainPresentation(train: train, at: entry.date).inlineText
        case let .ended(train): WidgetTrainPresentation(train: train, at: entry.date).inlineText
        }
    }

    private var symbol: String {
        if case let .train(train, _) = entry.display, train.isCancelled { return "xmark.circle" }
        return TrainTrackerSymbol.train
    }
}

/// Route codes, the anchor time with its status, then the platform or next stop.
struct NextTrainRectangularView: View {
    let entry: NextTrainEntry

    var body: some View {
        Group {
            switch entry.display {
            case .empty:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Roundhouse", image: TrainTrackerSymbol.train)
                        .font(.headline)
                        .widgetAccentable()
                    Text("No trains tracked")
                        .font(.subheadline)
                    Text("Tap to add a journey")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case let .train(train, _):
                ticket(WidgetTrainPresentation(train: train, at: entry.date))
            case let .ended(train):
                ticket(WidgetTrainPresentation(train: train, at: entry.date))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ticket(_ presentation: WidgetTrainPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(ttSymbol: presentation.status == .cancelled ? "xmark.circle" : TrainTrackerSymbol.train)
                    .font(.caption.weight(.semibold))
                Text(routeText(presentation))
            }
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .widgetAccentable()

            ViewThatFits(in: .horizontal) {
                timeRow(presentation, showsLabel: true)
                timeRow(presentation, showsLabel: false)
            }

            Text(presentation.rectangularDetail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
    }

    /// Codes fit as a pair; long names show only the station that matters now.
    private func routeText(_ presentation: WidgetTrainPresentation) -> String {
        if presentation.hasCodes { return "\(presentation.originLabel) → \(presentation.destinationLabel)" }
        return presentation.anchor == .departs ? presentation.originLabel : "To \(presentation.destinationLabel)"
    }

    private func timeRow(_ presentation: WidgetTrainPresentation, showsLabel: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if showsLabel {
                Text(presentation.anchor.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            presentation.anchorText(font: .title3.weight(.bold))
            if let zone = presentation.anchorZone {
                Text(zone).font(.caption2).foregroundStyle(.secondary)
            }
            // "Arrived" already labels the time.
            if presentation.status != .arrived {
                Text(presentation.statusText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A gauge that drains over the hour before departure and fills along the leg once underway,
/// around the station code and its time.
struct NextTrainCircularView: View {
    let entry: NextTrainEntry

    var body: some View {
        switch entry.display {
        case .empty:
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .accessibilityLabel("No trains tracked. Add a journey.")
        case let .train(train, _):
            gauge(WidgetTrainPresentation(train: train, at: entry.date))
        case let .ended(train):
            gauge(WidgetTrainPresentation(train: train, at: entry.date))
        }
    }

    @ViewBuilder
    private func gauge(_ presentation: WidgetTrainPresentation) -> some View {
        if presentation.status == .cancelled {
            VStack(spacing: 0) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                Text(presentation.train.boarding?.code ?? RunningStatusWords.canceled)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilitySummary)
        } else {
            Gauge(value: fraction(presentation)) {
                Text(presentation.anchor.rawValue)
            } currentValueLabel: {
                VStack(spacing: -1) {
                    if let label = stationLabel(presentation) {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Text(presentation.anchorCompactTimeText)
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if case let .delayed(minutes) = presentation.status {
                        Text("+\(minutes)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 2)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilitySummary)
        }
    }

    /// Before departure: the share of the final hour still to wait. Underway: the leg covered.
    private func fraction(_ presentation: WidgetTrainPresentation) -> Double {
        switch presentation.phase {
        case .upcoming:
            guard let departure = presentation.train.departure?.effective else { return 1 }
            return min(1, max(0, departure.timeIntervalSince(presentation.date) / 3_600))
        case .underway: return presentation.legProgress
        case .arrived, .cancelled: return 1
        }
    }

    /// The station's code only; a name never fits inside the ring.
    private func stationLabel(_ presentation: WidgetTrainPresentation) -> String? {
        presentation.anchor == .departs ? presentation.train.boarding?.code : presentation.train.alighting?.code
    }
}
