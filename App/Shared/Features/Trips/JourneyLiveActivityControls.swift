import SwiftUI
import TrainTrackerCore

struct JourneyLiveActivityControls: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var plans: JourneyPlanLibrary?
    @State private var manager = TrainLiveActivityManager.shared
    @State private var errorMessage: String?
    @State private var confirmsReplacement = false
    let trip: TrainTrip
    let selectedSegment: JourneyPlanSegment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isShowingSelection {
                Label("Showing on your Lock Screen", systemImage: "platter.filled.bottom.iphone")
                    .font(.subheadline.weight(.semibold))
                if let message = manager.deliveryMessage {
                    Text(message).font(.caption).foregroundStyle(Color.ttTextSecondary)
                }
                Button {
                    Task { await manager.stop() }
                } label: {
                    Label("End Live Activity", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if !manager.areActivitiesEnabled {
                Text("Allow Live Activities in Settings to see this train on your Lock Screen.")
                    .font(.subheadline).foregroundStyle(Color.ttTextSecondary)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .font(.subheadline.weight(.semibold))
            } else {
                Button {
                    if manager.activeAttributes != nil { confirmsReplacement = true }
                    else { start() }
                } label: {
                    Label("Show on Lock Screen", systemImage: "platter.filled.bottom.iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(manager.isBusy || !isEligible)
                Text(availabilityText)
                    .font(.caption).foregroundStyle(Color.ttTextSecondary)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TrainTrackerSpacing.space16)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
        .confirmationDialog("Replace your current Live Activity?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button("Show this train") { start() }
        } message: {
            Text("Your Lock Screen will follow this train. Both trains stay saved in My Trips.")
        }
        .alert("Live Activity", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var selection: TrainLiveActivitySelection? {
        TrainLiveActivitySelection(trip: trip, segment: selectedSegment, plans: plans?.plans ?? [])
    }

    private var eligibility: TrainLiveActivityProjection.Eligibility {
        selection?.projection(at: .now, checkedAt: library.lastSuccessfulCheck(for: trip.id),
            refreshFailed: library.lastRefreshFailed(for: trip.id)).eligibility ?? .unavailable
    }

    private var isEligible: Bool { eligibility == .available }

    private var isShowingSelection: Bool {
        guard let active = manager.activeAttributes, let selection else { return false }
        return active.tripID == trip.id.rawValue
            && active.boardingStationID == selection.boarding.station.id.rawValue
            && active.alightingStationID == selection.alighting.station.id.rawValue
    }

    private var availabilityText: String {
        switch eligibility {
        case .available: "See this train’s next stop, time, and platform without opening the app."
        case let .tooEarly(date): "Available from \(date.formatted(date: .abbreviated, time: .shortened)), one hour before departure."
        case .ended: "The saved arrival time has passed. Refresh if the train is delayed."
        case .cancelled: "A Live Activity can’t start for a canceled train or stop."
        case .unavailable: "Choose a clear train leg with a boarding station, destination, and timetable."
        }
    }

    private func start() {
        manager.connect(library: library, plans: plans)
        Task {
            do { try await manager.start(tripID: trip.id, segment: selectedSegment) }
            catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
