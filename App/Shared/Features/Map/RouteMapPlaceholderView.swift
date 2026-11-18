import SwiftUI
import TrainTrackerCore

struct RouteMapPlaceholderView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyIntakeModel.self) private var intake
    @StateObject private var locationPermission = MapLocationPermissionController()
    @SceneStorage("routeMap.selectedTripID") private var selectedTripIDValue: String?
    let isSelected: Bool

    init(isSelected: Bool = true) {
        self.isSelected = isSelected
    }

    var body: some View {
        Group {
            if let trip = selectedTrip {
                TripRouteMapView(
                    trip: trip,
                    chrome: .full,
                    trips: mappedTrips,
                    selectTrip: select,
                    isRefreshing: library.isRefreshing,
                    refreshTrip: { refresh(trip.id) },
                    refreshDidFail: { library.lastRefreshFailed(for: trip.id) },
                    userLocation: locationPermission.location
                )
            } else {
                ContentUnavailableView {
                    Label("No trip to map", systemImage: "map")
                } description: {
                    Text("Add a journey to see its route and the train’s live or estimated position when available.")
                } actions: {
                    Button {
                        intake.presentAddJourney()
                    } label: {
                        Text("Add Journey")
                            .padding(.horizontal, TrainTrackerSpacing.space12)
                    }
                    .trainTrackerPrimaryAction()
                    .controlSize(.large)
                    .accessibilityIdentifier("addJourneyMapEmptyState")
                }
            }
        }
        .background(Color.ttBackgroundCanvas)
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.ttBackgroundCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // With a route on screen the map runs edge to edge and the tabs float over it, as in
        // Maps; the trip summary names the train, so the bar would only repeat "Map".
        .toolbarVisibility(selectedTrip == nil ? .automatic : .hidden, for: .navigationBar)
        .task(id: mapLocationTaskID) {
            locationPermission.requestWhenInUseIfNeeded(
                isMapSelected: isSelected && selectedTrip != nil
            )
            synchronizeSelection()
        }
        .onChange(of: library.trips.map(\.id)) { _, _ in
            synchronizeSelection()
        }
    }

    private var mapLocationTaskID: String {
        [String(isSelected), selectedTrip?.id.rawValue ?? "none"].joined(separator: "-")
    }

    private var mappedTrips: [TrainTrip] {
        let activeTrips = library.trips.filter { !$0.isComplete }
        return activeTrips.isEmpty ? library.trips : activeTrips
    }

    private var selectedTrip: TrainTrip? {
        if let selectedTripID = selectedTripIDValue.map(RailIdentifier.init(rawValue:)),
           let selected = mappedTrips.first(where: { $0.id == selectedTripID }) {
            return selected
        }
        return library.activeTrip ?? mappedTrips.first
    }

    private func synchronizeSelection() {
        guard let trip = selectedTrip else {
            selectedTripIDValue = nil
            return
        }
        if selectedTripIDValue != trip.id.rawValue {
            selectedTripIDValue = trip.id.rawValue
        }
    }

    private func select(_ trip: TrainTrip) {
        selectedTripIDValue = trip.id.rawValue
    }

    private func refresh(_ tripID: RailIdentifier) {
        Task { await library.refreshTrackedTrip(id: tripID) }
    }
}
