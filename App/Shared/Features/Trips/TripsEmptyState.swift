import SwiftUI

/// The regular-width invitation; navigation and intake stay with My Trips.
struct TripsEmptyState: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let showsWordmark: Bool
    let addJourney: () -> Void
    let search: () -> Void

    var body: some View {
        ContentUnavailableView {
            if showsWordmark && !dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: TrainTrackerSpacing.space16) {
                    RoundhouseWordmark(width: 140)
                        .foregroundStyle(Color.ttTextBrand)
                        .accessibilityHidden(true)
                    Text("No journeys yet")
                        .font(.title3.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                }
            } else {
                Label("No journeys yet", image: TrainTrackerSymbol.train)
            }
        } description: {
            Text("Add a journey from your ticket, Calendar or a train search to follow live times, platform changes and service alerts.")
        } actions: {
            Button(action: addJourney) {
                Text("Add Journey")
                    .padding(.horizontal, TrainTrackerSpacing.space12)
            }
            .trainTrackerPrimaryAction()
            .controlSize(.large)
            .accessibilityIdentifier("addJourneyEmptyState")

            Button("Search for a Train", action: search)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("searchTrainEmptyState")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TrainTrackerSpacing.space24)
    }
}
