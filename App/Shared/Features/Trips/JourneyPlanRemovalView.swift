import SwiftUI
import TrainTrackerCore

struct JourneyPlanRemovalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(JourneyIntakeModel.self) private var intake

    let controller: JourneyPlanRemovalController
    let trips: [TrainTrip]

    var body: some View {
        let presentation = JourneyPlanRemovalPresentation(
            preview: controller.preview,
            trips: trips
        )

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                    warning(message: presentation.warningMessage)
                    childSection(
                        title: JourneySearchCopy.Plan.willStopTracking,
                        children: presentation.removableChildren,
                        emptyMessage: JourneySearchCopy.Plan.noRemovableTrains
                    )
                    childSection(
                        title: JourneySearchCopy.Plan.willRemainTracked,
                        children: presentation.preservedChildren,
                        emptyMessage: JourneySearchCopy.Plan.noPreservedTrains
                    )
                    childSection(
                        title: JourneySearchCopy.Plan.noLongerTracked,
                        children: presentation.missingChildren,
                        emptyMessage: JourneySearchCopy.Plan.allStillTracked
                    )

                    if let failure = controller.failureMessage {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.ttStatusDelayed)
                            .accessibilityElement(children: .combine)
                    }

                    Button(role: presentation.hasTrackedTrainsToRemove ? .destructive : nil) {
                        let succeeded = presentation.hasTrackedTrainsToRemove
                            ? controller.stopTrackingChildren()
                            : controller.removeGrouping()
                        if succeeded {
                            if !presentation.hasTrackedTrainsToRemove, let removed = controller.removedGroup {
                                intake.offerUndo(restoring: removed)
                            }
                            dismiss()
                        }
                    } label: {
                        Text(presentation.actionTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(presentation.hasTrackedTrainsToRemove ? Color.ttStatusCancelled : Color.ttBackgroundBrand)
                    .controlSize(.large)
                    .accessibilityLabel(presentation.actionTitle)
                    .accessibilityHint(
                        presentation.hasTrackedTrainsToRemove
                            ? JourneySearchCopy.Accessibility.stopTrackingJourneyTrains.hint
                            : JourneySearchCopy.Accessibility.removeJourneyGroup.hint
                    )
                }
                .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                .padding(LayoutMetrics.pageInset)
                .frame(maxWidth: .infinity)
            }
            .background(Color.ttBackgroundCanvas)
            .navigationTitle(
                presentation.hasTrackedTrainsToRemove
                    ? JourneySearchCopy.Plan.stopTrackingTitle
                    : JourneySearchCopy.Plan.removeGroupTitle
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(JourneySearchCopy.cancel) { dismiss() }
                }
            }
        }
    }

    private func warning(message: String) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Label(
                JourneySearchCopy.Plan.reviewBeforeRemoving,
                systemImage: "exclamationmark.triangle.fill"
            )
                .font(.headline)
                .foregroundStyle(Color.ttStatusCancelled)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .padding(LayoutMetrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.ttStatusCancelled.opacity(0.08),
            in: RoundedRectangle(cornerRadius: TrainTrackerRadius.group, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func childSection(
        title: String,
        children: [JourneyPlanRemovalPresentation.Child],
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)

            if children.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        removalRow(child)
                        if index < children.count - 1 {
                            Divider().overlay(Color.ttBorderSubtle)
                        }
                    }
                }
                .padding(.horizontal, LayoutMetrics.cardInset)
                .trainTrackerSurface(radius: TrainTrackerRadius.group)
            }
        }
    }

    private func removalRow(_ child: JourneyPlanRemovalPresentation.Child) -> some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
            Image(systemName: iconName(for: child.reason))
                .foregroundStyle(iconColor(for: child.reason))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(tripLabel(for: child.id))
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                Text(child.reasonText)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, TrainTrackerSpacing.space12)
        .accessibilityElement(children: .combine)
    }

    private func tripLabel(for id: RailIdentifier) -> String {
        trips.first(where: { $0.id == id })?.product ?? JourneySearchCopy.Plan.journeyTrain
    }

    private func iconName(for reason: JourneyPlanRemovalPresentation.Child.Reason) -> String {
        switch reason {
        case .removable: "minus.circle.fill"
        case .missing: "xmark.circle.fill"
        case .shared, .preExisting, .sharedAndPreExisting: "checkmark.shield.fill"
        }
    }

    private func iconColor(for reason: JourneyPlanRemovalPresentation.Child.Reason) -> Color {
        switch reason {
        case .removable: Color.ttStatusCancelled
        case .missing: Color.ttTextSecondary
        case .shared, .preExisting, .sharedAndPreExisting: Color.ttStatusOnTime
        }
    }
}
