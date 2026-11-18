import SwiftUI
import TrainTrackerCore

enum JourneyOptionRowLayout {
    static let serviceSeparator = "  •  "

    /// A multi-leg service identity carries the operator and train number of every leg, and the
    /// final train number is what a traveller matches against a station board. Allow bounded
    /// vertical growth instead of truncating it away on iPhone widths.
    static func serviceLineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 4 : 2
    }

    /// Keeps each leg's operator and train number together on one line, so the two-line treatment
    /// wraps between legs rather than between an operator and the train number it identifies.
    static func serviceSummary(trainIdentities: [String], changes: String) -> String {
        guard !trainIdentities.isEmpty else { return changes }
        return trainIdentities
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: serviceSeparator)
    }
}

struct JourneyOptionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let option: JourneyOption
    let presentation: JourneyOptionPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            if let recommendation = presentation.recommendationBadge {
                Text(recommendation.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.ttTextOperational)
                    .accessibilityLabel(recommendation)
            }

            if dynamicTypeSize.isAccessibilitySize {
                accessibleTimeLayout
            } else {
                compactTimeLayout
            }

            journeySummary

            if presentation.status == JourneySearchCopy.Status.cancelled {
                Label(JourneySearchCopy.Status.cancelled, systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ttStatusCancelled)
            }

            if let warning = presentation.transferWarning {
                Label(warning, systemImage: "figure.walk.motion")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ttStatusDelayed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            operationalDetails
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("journey-option-\(option.id)")
    }

    private var compactTimeLayout: some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space8) {
            endpoint(
                time: presentation.time.departure,
                station: presentation.originStation,
                alignment: .leading
            )

            routeBridge

            endpoint(
                time: presentation.time.arrival,
                dayContext: presentation.time.arrivalDayContext,
                station: presentation.destinationStation,
                alignment: .trailing
            )
        }
    }

    private var routeBridge: some View {
        VStack(spacing: TrainTrackerSpacing.space6) {
            Text(presentation.time.duration)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.ttTextSecondary)

            HStack(spacing: TrainTrackerSpacing.space2) {
                Circle()
                    .frame(width: 6, height: 6)
                Rectangle()
                    .frame(height: 2)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(Color.ttRouteActive)
        }
        .frame(width: 82)
        .padding(.top, TrainTrackerSpacing.space2)
        .accessibilityHidden(true)
    }

    private var accessibleTimeLayout: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            labelledEndpoint(
                label: JourneySearchCopy.Detail.departure,
                time: presentation.time.departure,
                station: presentation.originStation
            )
            labelledEndpoint(
                label: JourneySearchCopy.Detail.arrival,
                time: presentation.time.arrival,
                dayContext: presentation.time.arrivalDayContext,
                station: presentation.destinationStation
            )
            Label(presentation.time.duration, systemImage: "clock")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.ttTextSecondary)
        }
    }

    private var journeySummary: some View {
        Group {
            // A multi-leg service wraps between its legs; the change count then gets its own
            // line instead of trailing a "•" leg separator as "• · 1 change".
            if dynamicTypeSize.isAccessibilitySize
                || serviceSummary.contains(JourneyOptionRowLayout.serviceSeparator) {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    serviceLabel
                    Text(presentation.changes)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space6) {
                    serviceLabel
                    Text("·")
                        .accessibilityHidden(true)
                    Text(presentation.changes)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .font(.subheadline)
    }

    private var serviceLabel: some View {
        Text(serviceSummary)
            .foregroundStyle(Color.ttTextSecondary)
            .lineLimit(JourneyOptionRowLayout.serviceLineLimit(for: dynamicTypeSize))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var trackingLabel: some View {
        Label(
            presentation.trackability,
            systemImage: presentation.trackability == JourneySearchCopy.Status.trackingUnavailable
                ? "bell.slash"
                : "bell.badge"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(trackingColor)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var operationalDetails: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                trackingLabel
                if presentation.departurePlatform != nil || presentation.arrivalPlatform != nil {
                    platformLabel
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TrainTrackerSpacing.space6) {
                    trackingLabel
                    if presentation.departurePlatform != nil || presentation.arrivalPlatform != nil {
                        Text("·")
                            .accessibilityHidden(true)
                        platformLabel
                    }
                }

                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                    trackingLabel
                    if presentation.departurePlatform != nil || presentation.arrivalPlatform != nil {
                        platformLabel
                    }
                }
            }
        }
    }

    private var platformLabel: some View {
        Label(platformSummary, systemImage: "signpost.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.ttTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var serviceSummary: String {
        JourneyOptionRowLayout.serviceSummary(
            trainIdentities: presentation.trainIdentities,
            changes: presentation.changes
        )
    }

    private var platformSummary: String {
        switch (presentation.departurePlatform, presentation.arrivalPlatform) {
        case let (departure?, arrival?): "\(departure) → \(arrival)"
        case let (departure?, nil): departure
        case let (nil, arrival?): arrival
        case (nil, nil): ""
        }
    }

    private var trackingColor: Color {
        presentation.trackability == JourneySearchCopy.Status.trackingUnavailable
            ? Color.ttTextSecondary
            : Color.ttTextOperational
    }

    private func endpoint(
        time: String,
        dayContext: String? = nil,
        station: String,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: TrainTrackerSpacing.space4) {
            timeLine(time: time, dayContext: dayContext)
            Text(station)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.ttTextSecondary)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                // Station names wrap rather than truncate; the top-aligned row keeps both
                // times on one line however many lines either name takes.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func labelledEndpoint(
        label: String,
        time: String,
        dayContext: String? = nil,
        station: String
    ) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.ttTextSecondary)
            timeLine(time: time, dayContext: dayContext)
            Text(station)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timeLine(time: String, dayContext: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space4) {
            Text(time)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.ttTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            if let dayContext {
                Text(dayContext)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ttStatusDelayed)
            }
        }
    }
}
