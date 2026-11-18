import SwiftUI
import TrainTrackerCore

struct MeetTrainAction: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var plans: JourneyPlanLibrary?
    @Environment(\.journeyReferenceDate) private var referenceDate
    @State private var presentsComposer = false
    let trip: TrainTrip
    let selectedSegment: JourneyPlanSegment?

    var body: some View {
        let selection = MeetTrainSelection(trip: trip, segment: selectedSegment,
                                          watching: library.isWatchingOnly(trip.id), at: referenceDate ?? .now)
        if !selection.calls.isEmpty {
            Button { presentsComposer = true } label: {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    Image(systemName: "person.2").font(.title3)
                    Text("Meet My Train").font(.body.weight(.semibold)).foregroundStyle(Color.ttTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                }
                .padding(LayoutMetrics.cardInset)
                .contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(Color.ttActionTint)
            .trainTrackerSurface().accessibilityIdentifier("meetMyTrain")
            .accessibilityHint("Creates an arrival board for the person meeting you")
            .sheet(isPresented: $presentsComposer) {
                MeetTrainComposer(trip: trip, selection: selection, segment: selectedSegment, plans: plans?.plans ?? [])
                    .id(trip.id)
            }
        }
    }
}
