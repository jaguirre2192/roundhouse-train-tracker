import SwiftUI

struct JourneyNavigationDestination: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var plans
    let request: JourneyNavigationRequest

    var body: some View {
        if let trip = library.trip(id: request.tripID) {
            let segment = request.selectedSegment(trip: trip, plans: plans.plans)
            if request.boardingStationID != nil && segment == nil {
                ContentUnavailableView("Journey section unavailable", image: TrainTrackerSymbol.train,
                    description: Text("The saved train’s stops have changed. Open it from My Trips to review the latest route."))
            } else {
                TripDetailView(trip: trip, selectedSegment: segment)
            }
        } else {
            ContentUnavailableView("Train no longer saved", image: TrainTrackerSymbol.train,
                description: Text("Choose another train from My Trips."))
        }
    }
}
