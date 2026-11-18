import SwiftUI

struct TrainActivityExpandedView: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrainActivityJourneySummary(presentation: presentation)
            TrainActivityFooter(presentation: presentation)
        }
        .foregroundStyle(TrainActivityPalette.primary)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilitySummary)
    }
}

struct TrainActivityCompactLeadingView: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        Image(ttSymbol: presentation.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(TrainActivityPalette.status(for: presentation))
            .frame(width: 22)
            .accessibilityLabel(presentation.attributes.serviceName)
    }
}

struct TrainActivityCompactTrailingView: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        Text(presentation.compactText)
            .font(.caption.weight(.semibold).monospacedDigit())
            // A saved time is still the time to glance at, but never as bright as a checked one.
            .foregroundStyle(presentation.isStale ? TrainActivityPalette.secondary : TrainActivityPalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: 58)
            .accessibilityLabel(presentation.accessibilitySummary)
    }
}

struct TrainActivityMinimalView: View {
    let presentation: TrainActivityPresentation

    var body: some View {
        Image(ttSymbol: presentation.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(TrainActivityPalette.status(for: presentation))
            .accessibilityLabel(presentation.accessibilitySummary)
    }
}
