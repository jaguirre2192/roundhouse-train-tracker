import SwiftUI

/// A short-lived confirmation with Undo for the most recent reversible addition.
struct JourneyIntakeUndoBanner: View {
    @Environment(JourneyIntakeModel.self) private var intake
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        if let undo = intake.undo, intake.presentation == nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    message(undo)
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    actions
                }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    message(undo)
                    HStack(spacing: TrainTrackerSpacing.space12) { actions }
                }
            }
            .padding(.horizontal, LayoutMetrics.cardInset)
            .padding(.vertical, TrainTrackerSpacing.space12)
            .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
            .trainTrackerSurface(color: .ttBackgroundElevated, radius: TrainTrackerRadius.control, elevation: TrainTrackerElevation.overlay)
            .padding(.horizontal, LayoutMetrics.pageInset)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .task(id: undo.id) {
                // VoiceOver users keep the action until they dismiss it.
                guard !voiceOverEnabled else { return }
                try? await Task.sleep(for: .seconds(12))
                if intake.undo?.id == undo.id { intake.clearUndo() }
            }
        }
    }

    private func message(_ undo: JourneyIntakeModel.UndoAction) -> some View {
        Label(undo.message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("journeyIntakeUndoMessage")
    }

    @ViewBuilder
    private var actions: some View {
        Button("Undo") { intake.performUndo(planLibrary: planLibrary) }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .accessibilityIdentifier("journeyIntakeUndo")
            .accessibilityHint("Removes only what this action added. Your ticket stays saved.")
        Button {
            intake.clearUndo()
        } label: {
            Image(systemName: "xmark")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ttTextSecondary)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("journeyIntakeUndoDismiss")
    }
}
