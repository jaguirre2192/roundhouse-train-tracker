import SwiftUI

/// One quiet, tappable line of operational context directly beneath the ticket.
struct TripUpdatesRow: View {
    @Environment(TripLibrary.self) private var library: TripLibrary?
    @State private var showsHistory = false
    let experience: JourneyExperiencePresentation

    var body: some View {
        let updates = TripUpdatePresentation(experience: experience, journal: library?.changeJournal(for: experience.trip.id) ?? TripChangeJournal())
        if let line = updates.headline {
            Button { showsHistory = true } label: {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    Image(systemName: line.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ttActionTint)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                        Text(line.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ttTextPrimary)
                        Text(line.detail).font(.caption).foregroundStyle(Color.ttTextSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ttActionTint).accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(line.title). \(line.detail)")
            .accessibilityHint("Shows recent train updates")
            .accessibilityIdentifier("recentTrainUpdates")
            .sheet(isPresented: $showsHistory) {
                history(updates)
            }
        }
    }

    private func history(_ updates: TripUpdatePresentation) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space20) {
                    Text(experience.serviceTitle)
                        .font(.headline).foregroundStyle(Color.ttTextPrimary)
                    if let note = updates.positionNote { entry(note) }
                    ForEach(updates.changes) { line in
                        Divider()
                        entry(line)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(LayoutMetrics.pageInset)
                .frame(maxWidth: .infinity)
            }
            .trainTrackerPageBackground()
            .navigationTitle("Recent Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHistory = false } }
            }
            .accessibilityIdentifier("trainUpdateHistory")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func entry(_ line: TripUpdatePresentation.Line) -> some View {
        Label {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(line.title).font(.body.weight(.medium)).foregroundStyle(Color.ttTextPrimary)
                Text(line.detail).font(.subheadline).foregroundStyle(Color.ttTextSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: line.symbol).font(.body).foregroundStyle(Color.ttActionTint)
        }
        .accessibilityElement(children: .combine)
    }
}
