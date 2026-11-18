import SwiftUI
import TrainTrackerCore

/// A tracked train opens its own live guide. The Travel Log also keeps a browsable copy.
struct WindowSeatLink: View {
    var trip: TrainTrip? = nil
    var selectedStops: [StopTime]? = nil
    @Environment(\.journeyReferenceDate) private var referenceDate
    @State private var isPresented = false

    var body: some View {
        if trip.map({ HudsonWindowGuide.matches($0, stops: selectedStops) }) ?? true {
            Button { isPresented = true } label: {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    Image("HudsonWindowSeat")
                        .resizable().scaledToFill()
                        .frame(width: 62, height: 48)
                        .clipShape(.rect(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Window Seat").font(.headline).foregroundStyle(Color.ttTextPrimary)
                        Text("The Hudson Valley · Illustrated guide")
                            .font(.footnote).foregroundStyle(Color.ttTextSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Color.ttTextOperational)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openWindowSeat")
            .fullScreenCover(isPresented: $isPresented) {
                WindowSeatView(trip: trip, selectedStops: selectedStops, now: referenceDate ?? .now)
            }
        }
    }
}
