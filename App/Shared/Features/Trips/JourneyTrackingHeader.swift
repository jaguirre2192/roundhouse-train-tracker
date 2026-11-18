import SwiftUI
import TrainTrackerCore

/// The rider's next useful facts, using the same event, timezone and evidence as the route.
struct JourneyTrackingHeader: View {
    let experience: JourneyExperiencePresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(TripLibrary.self) private var library: TripLibrary?
    @Environment(JourneyPlanLibrary.self) private var plans: JourneyPlanLibrary?

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(experience.focusLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ttTextSecondary)
            Text(experience.focusName)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.ttTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("journeyFocusStation")

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) { timing; platform }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space20) {
                        timing
                        platform
                    }
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                        timing
                        platform
                    }
                }
            }

            Text(presentation.statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyNextStopHeader")
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            if let time = experience.focusTimeText {
                Text(time)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ttTextPrimary)
                Text([experience.timingLabel, experience.countdownText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var platform: some View {
        if let board = PlatformBoardPresentation(
            experience: experience, journal: library?.changeJournal(for: experience.trip.id) ?? .init(),
            watching: library?.isWatchingOnly(experience.trip.id) == true, plans: plans?.plans ?? []
        ) {
            NavigationLink {
                PlatformBoardView(experience: experience)
            } label: {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    HStack(spacing: TrainTrackerSpacing.space4) {
                        Text(board.number ?? "View board").font(.title3.weight(.semibold).monospacedDigit())
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.bold)).accessibilityHidden(true)
                    }
                    Text(board.previous == nil ? board.noun : "\(board.noun) changed")
                        .font(.caption).foregroundStyle(Color.ttTextSecondary)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ttActionTint)
            .accessibilityLabel("Platform View, \(board.noun) \(board.number ?? "awaiting assignment")")
            .accessibilityIdentifier("openPlatformBoard")
        } else if let value = presentation.platformValue {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(platformColor)
                Text(presentation.platformLabel)
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.platformAccessibilityText)
        }
    }

    private var presentation: JourneyTrackingHeaderPresentation {
        JourneyTrackingHeaderPresentation(experience: experience)
    }

    private var platformColor: Color {
        if presentation.isPlatformChanged { return .ttStatusDelayed }
        return presentation.isPlatformPredicted ? .ttActionLive : .ttTextPrimary
    }

    private var statusColor: Color {
        let freshness = TripFreshness(lastSuccessfulCheck: experience.lastSuccessfulCheck, lastRefreshFailed: experience.refreshFailed)
        return freshness.isConfirmed && presentation.statusKind.isDisruption ? presentation.statusKind.color : .ttTextSecondary
    }
}
