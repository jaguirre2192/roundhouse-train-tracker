import SwiftUI
import TrainTrackerCore

struct JourneyReviewDirectionSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let option: JourneyOption
    /// This direction as the backend resolved it. Nil while the check is still running.
    var resolution: JourneyPlanResolution.Direction?

    private var presentation: JourneyOptionPresentation {
        JourneyOptionPresentation(option: option)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            directionHeader

            ForEach(option.segments) { segment in
                switch segment {
                case let .rail(rail):
                    JourneyReviewRailLegRow(
                        rail: rail,
                        resolved: resolution?.coverageSegment(matching: rail.id),
                        hasResolvedDirection: resolution != nil
                    )
                case let .walk(walk):
                    JourneyReviewTransferRow(walk: walk)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var directionHeader: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(title)
                .font(.title3.weight(.bold))

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                        directionTimeContent(arrow: "arrow.down")
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                        directionTimeContent(arrow: "arrow.right")
                    }
                }
            }
            .font(.headline.monospacedDigit())

            Text("\(presentation.originStation) to \(presentation.destinationStation)")
                .font(.subheadline.weight(.semibold))

            Text("\(presentation.time.duration) · \(presentation.changes)")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(color: .ttBackgroundBrandSubtle, radius: TrainTrackerRadius.group)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(presentation.accessibilityLabel)")
    }

    @ViewBuilder
    private func directionTimeContent(arrow: String) -> some View {
        Text(presentation.time.departure)
        Image(systemName: arrow)
            .foregroundStyle(Color.ttRouteActive)
            .accessibilityHidden(true)
        Text(presentation.time.arrival)
        if let dayContext = presentation.time.arrivalDayContext {
            Text(dayContext)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.ttStatusDelayed)
        }
    }
}

private struct JourneyReviewRailLegRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let rail: RailJourneySegment
    let resolved: JourneyPlanResolution.Segment?
    let hasResolvedDirection: Bool

    private var presentation: JourneySegmentPresentation {
        JourneySegmentPresentation.make(from: .rail(rail))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            railHeading
            endpoints

            coverageLine

            if rail.isCancelled {
                Label(JourneySearchCopy.Status.cancelled, systemImage: "xmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ttStatusCancelled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
        .accessibilityElement(children: .combine)
    }

    /// What this train's sources provide. Empty while the check runs; a train that cannot be
    /// followed at all keeps its stated reason.
    @ViewBuilder
    private var coverageLine: some View {
        if !rail.isTrackable {
            unavailable(presentation.trackability ?? JourneySearchCopy.Detail.trackabilityUnavailable)
        } else if let resolved {
            if resolved.trip != nil {
                JourneyCoverageRow(disclosure: JourneyCoverageDisclosure(coverage: resolved.coverage))
            } else if resolved.failure?.code == .providerUnavailable {
                JourneyCoverageRow(disclosure: JourneyCoverageDisclosure(coverage: .unavailable))
            } else {
                unavailable(JourneySearchCopy.Status.trackingUnavailable)
            }
        } else if hasResolvedDirection {
            JourneyCoverageRow(disclosure: JourneyCoverageDisclosure(coverage: .unconfirmed))
        }
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "bell.slash.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttStatusDelayed)
    }

    @ViewBuilder
    private var railHeading: some View {
        let content = VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.subtitle ?? rail.product)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                Image(TrainTrackerSymbol.train)
                    .foregroundStyle(Color.ttActionLive)
                    .accessibilityHidden(true)
                content
            }
        } else {
            HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                Image(TrainTrackerSymbol.train)
                    .foregroundStyle(Color.ttActionLive)
                    .frame(width: LayoutMetrics.iconRailWidth)
                    .accessibilityHidden(true)
                content
            }
        }
    }

    @ViewBuilder
    private var endpoints: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                endpoint(presentation.calls.first, label: JourneySearchCopy.Detail.board)
                Image(systemName: "arrow.down")
                    .foregroundStyle(Color.ttRouteActive)
                    .accessibilityHidden(true)
                endpoint(presentation.calls.last, label: JourneySearchCopy.Detail.alight)
            }
        } else {
            HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                endpoint(presentation.calls.first, label: JourneySearchCopy.Detail.board)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Color.ttRouteActive)
                    .padding(.top, TrainTrackerSpacing.space20)
                    .accessibilityHidden(true)
                endpoint(presentation.calls.last, label: JourneySearchCopy.Detail.alight)
            }
        }
    }

    private func endpoint(
        _ call: JourneyCallPresentation?,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.ttTextSecondary)
            Text(call?.displayTime ?? JourneySearchCopy.Detail.timeUnavailable)
                .font(.body.weight(.bold).monospacedDigit())
            Text(call?.station ?? JourneySearchCopy.Detail.stationUnavailable)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let platform = call?.platform {
                Text(platform)
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct JourneyReviewTransferRow: View {
    let walk: WalkJourneySegment

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(
                    walk.isStationChange
                        ? JourneySearchCopy.Detail.stationTransfer
                        : JourneySearchCopy.Detail.transferWalk
                )
                    .font(.subheadline.weight(.semibold))
                Text(JourneySearchCopy.Status.route(
                    from: walk.from.displayName,
                    to: walk.to.displayName
                ))
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        } icon: {
            Image(systemName: "figure.walk")
                .foregroundStyle(Color.ttStatusDelayed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(color: .ttBackgroundBrandSubtle, radius: TrainTrackerRadius.group)
        .accessibilityElement(children: .combine)
    }
}
