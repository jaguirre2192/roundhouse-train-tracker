import SwiftUI
import TrainTrackerCore

@MainActor
struct RoundTripReviewView: View {
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let store: JourneySearchStore
    /// Import review owns what happens after a successful save, such as linking a ticket.
    var onTracked: ((UUID) -> Void)?
    /// Ticket purchase is offered from search; an imported ticket is already bought.
    var offersTicketPurchase = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                resolutionContent

                if offersTicketPurchase, let outbound = store.selectedOutbound,
                   let journey = try? TicketPurchaseJourney(outbound: outbound, returnOption: store.selectedReturn),
                   journey.canSearch(at: .now) {
                    NavigationLink {
                        TicketPurchaseView(journey: journey)
                    } label: {
                        Label("Check Tickets", systemImage: "ticket")
                            .trainTrackerFullWidthAction()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Review scheduled journey details before searching and paying on Omio. Tracking does not reserve a ticket.")
                    .accessibilityIdentifier("checkJourneyTickets")
                }

                if let outbound = store.selectedOutbound {
                    JourneyReviewDirectionSection(
                        title: JourneySearchCopy.outbound,
                        option: outbound,
                        resolution: resolvedDirection(for: outbound)
                    )
                }
                if let returnOption = store.selectedReturn {
                    JourneyReviewDirectionSection(
                        title: JourneySearchCopy.returnDirection,
                        option: returnOption,
                        resolution: resolvedDirection(for: returnOption)
                    )
                }

                if let summary = store.resolutionSummary, summary.availableTripCount > 0 {
                    Link(destination: summary.coverage.detailsURL) {
                        Label(JourneySearchCopy.Coverage.details, systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint(JourneySearchCopy.Coverage.detailsHint)
                    .accessibilityIdentifier("journeyCoverageDetails")
                }
            }
            .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
            .padding(LayoutMetrics.pageInset)
            .frame(maxWidth: .infinity)
        }
        .background(Color.ttBackgroundCanvas)
        .navigationTitle(JourneySearchCopy.Review.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectionIdentity) {
            guard store.resolvedPlan == nil, store.phase == .reviewing else { return }
            store.resolveSelection()
        }
    }

    @ViewBuilder
    private var resolutionContent: some View {
        if store.phase == .resolving, store.resolvedPlan == nil {
            resolutionLoading
        } else if let summary = store.resolutionSummary {
            resolvedContent(summary)
        } else if store.phase == .failed(.trackingTokenExpired) {
            resolutionError(
                title: JourneySearchCopy.Review.detailsChangedTitle,
                message: JourneySearchCopy.Review.detailsChangedMessage
            )
        } else if store.phase == .failed(.resolutionUnavailable) {
            resolutionError(
                title: JourneySearchCopy.Review.unavailableTitle,
                message: JourneySearchCopy.Review.unavailableMessage
            )
        } else {
            resolutionLoading
        }
    }

    private var resolutionLoading: some View {
        HStack(spacing: TrainTrackerSpacing.space12) {
            ProgressView()
                .controlSize(.regular)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(JourneySearchCopy.Review.checkingTitle)
                    .font(.headline)
                Text(JourneySearchCopy.Review.checkingMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
        .accessibilityElement(children: .combine)
    }

    private func resolvedContent(_ summary: JourneyResolutionSummary) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            statusHeading(summary)

            if summary.state == .all, summary.coverage.notice == nil {
                Text(JourneySearchCopy.Review.readyCount(summary.availableTripCount))
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }

            if let notice = summary.coverage.notice {
                coverageNotice(notice)
            }

            if !summary.failures.isEmpty {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                    ForEach(summary.failures) { failure in
                        failureRow(failure)
                    }
                }
            }

            if summary.showsSubsetConsent {
                subsetConsent(summary)
            }

            if store.trackingFailed {
                Label(
                    JourneySearchCopy.Review.saveFailure,
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                if summary.showsRetryAction {
                    Button {
                        store.resolveSelection()
                    } label: {
                        Text(summary.retryActionTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button {
                    guard store.trackResolvedPlan() else { return }
                    if let onTracked, case let .completed(planID) = store.phase {
                        onTracked(planID)
                    } else {
                        navigation.open(.trips)
                    }
                } label: {
                    Text(summary.primaryActionTitle)
                        .frame(maxWidth: .infinity)
                }
                .trainTrackerPrimaryAction()
                .accessibilityIdentifier("trackResolvedJourney")
                .controlSize(.large)
                .disabled(!summary.canTrack || store.phase == .resolving)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.card, elevation: TrainTrackerElevation.card)
        .accessibilityElement(children: .contain)
    }

    /// Coverage gaps sit above Save as one inline notice. Only a diagnosed outage is a warning,
    /// and only then is there something to retry; nothing here disables saving.
    private func coverageNotice(_ notice: JourneyCoverageSummary.Notice) -> some View {
        TrainTrackerNotice(
            notice.title,
            message: notice.message,
            systemImage: notice.isOutage ? "exclamationmark.arrow.triangle.2.circlepath" : "info.circle",
            tone: notice.isOutage ? .warning : .informational
        ) {
            if notice.isOutage {
                Button(JourneySearchCopy.Coverage.checkAgain) { store.resolveSelection() }
                    .buttonStyle(.bordered)
                    .disabled(store.phase == .resolving)
            }
        }
        .accessibilityIdentifier("journeyCoverageNotice")
    }

    private func resolvedDirection(for option: JourneyOption) -> JourneyPlanResolution.Direction? {
        store.resolvedPlan?.directions.first { $0.fingerprint == option.fingerprint }
    }

    @ViewBuilder
    private func statusHeading(_ summary: JourneyResolutionSummary) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    Image(systemName: statusImage(for: summary.state))
                    Text(summary.statusTitle)
                }
                .accessibilityElement(children: .combine)
            } else {
                Label(summary.statusTitle, systemImage: statusImage(for: summary.state))
            }
        }
        .font(.headline)
        .foregroundStyle(statusColor(for: summary.state))
    }

    @ViewBuilder
    private func failureRow(_ failure: JourneyResolutionFailure) -> some View {
        let content = VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(failure.message)
                .font(.subheadline.weight(.semibold))
            Text(failureDirectionLabel(failure))
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
        }

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.ttStatusDelayed)
                    content
                }
            } else {
                Label {
                    content
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.ttStatusDelayed)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func subsetConsent(_ summary: JourneyResolutionSummary) -> some View {
        let consent = Binding(
            get: { store.availableSubsetConfirmed },
            set: { confirmed in
                store.setAvailableSubsetConfirmed(confirmed)
            }
        )

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                Text(summary.subsetConsentLabel)
                Toggle("", isOn: consent)
                    .labelsHidden()
                    .accessibilityLabel(summary.subsetConsentLabel)
            }
        } else {
            Toggle(summary.subsetConsentLabel, isOn: consent)
        }
    }

    private func resolutionError(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Label(title, systemImage: "arrow.clockwise.circle")
                .font(.headline)
                .foregroundStyle(Color.ttStatusDelayed)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
            Button(JourneySearchCopy.Review.retryTrackingCheck) {
                store.resolveSelection()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(JourneySearchCopy.Accessibility.retryTrackingCheck.label)
            .accessibilityHint(JourneySearchCopy.Accessibility.retryTrackingCheck.hint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
    }

    private func failureDirectionLabel(_ failure: JourneyResolutionFailure) -> String {
        if failure.directionFingerprint == store.selectedOutbound?.fingerprint {
            return JourneySearchCopy.Review.outboundTrain
        }
        if failure.directionFingerprint == store.selectedReturn?.fingerprint {
            return JourneySearchCopy.Review.returnTrain
        }
        return JourneySearchCopy.Review.selectedTrain
    }

    private var selectionIdentity: String {
        [store.selectedOutbound?.fingerprint, store.selectedReturn?.fingerprint]
            .compactMap { $0 }
            .joined(separator: ":")
    }

    private func statusImage(for state: JourneyResolutionSummary.State) -> String {
        switch state {
        case .all: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .none: "xmark.circle.fill"
        }
    }

    private func statusColor(for state: JourneyResolutionSummary.State) -> Color {
        switch state {
        case .all: .ttStatusOnTime
        case .partial: .ttStatusDelayed
        case .none: .ttStatusCancelled
        }
    }
}
