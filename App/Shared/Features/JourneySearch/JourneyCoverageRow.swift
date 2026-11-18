import SwiftUI

/// The quiet line at the foot of a train's review card: what its sources provide, in words.
/// Neutral unless a check actually failed; color never carries the meaning on its own.
struct JourneyCoverageRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// One column for every symbol, so the text of stacked trains starts on the same edge.
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth = 24.0

    let disclosure: JourneyCoverageDisclosure

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    icon
                    text
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                    icon.frame(width: LayoutMetrics.iconRailWidth)
                    text
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(disclosure.accessibilityLabel)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(titleColor)
            .frame(width: iconWidth, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(disclosure.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
            if let detail = disclosure.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var symbol: String {
        switch disclosure.kind {
        case .connected, .limited: "dot.radiowaves.left.and.right"
        case .scheduleOnly: "calendar"
        case .unconfirmed: "questionmark.circle"
        case .unavailableNow: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private var titleColor: Color {
        switch disclosure.kind {
        case .connected, .limited: .ttTextPrimary
        case .scheduleOnly, .unconfirmed: .ttTextSecondary
        case .unavailableNow: .ttStatusDelayed
        }
    }
}
