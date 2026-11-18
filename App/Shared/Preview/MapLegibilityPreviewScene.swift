#if DEBUG
import SwiftUI

struct MapLegibilityPreviewScene: View {
    private let fixture = JourneyExperiencePreviewData.make(.scheduled)

    var body: some View {
        NavigationStack {
            TripRouteMapView(trip: fixture.trips[0], chrome: .full)
                .navigationTitle("Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.ttBackgroundCanvas, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
#endif
