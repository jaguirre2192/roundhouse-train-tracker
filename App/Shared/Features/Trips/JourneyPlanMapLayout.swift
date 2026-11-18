import SwiftUI
import TrainTrackerCore

/// The plan keeps its state and ScrollView. Only its available train's map and panel placement
/// change on wide displays; an absent snapshot retains the readable scrolling layout.
struct JourneyPlanMapLayout<Content: View>: View {
    let trip: TrainTrip?
    let selectedSegment: JourneyPlanSegment?
    let referenceDate: Date
    let lastSuccessfulCheck: Date?
    let lastRefreshFailed: Bool
    let isRefreshing: Bool
    let refreshTrip: (() -> Void)?
    @ViewBuilder var content: (Bool) -> Content

    @State private var space = JourneyPanelGeometry()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesMapPanel: Bool { space.floatsBeside && trip != nil && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        Color.clear
            .onGeometryChange(for: JourneyPanelGeometry.self) { JourneyPanelGeometry($0) } action: {
                space = $0
            }
            .background {
                if usesMapPanel, let trip {
                    let card = ActiveTripCardPresentation(
                        trip: trip, referenceDate: referenceDate,
                        lastSuccessfulCheck: lastSuccessfulCheck,
                        lastRefreshFailed: lastRefreshFailed, selectedSegment: selectedSegment
                    )
                    TripRouteMapView(
                        trip: trip, chrome: .compact,
                        isRefreshing: isRefreshing, refreshTrip: refreshTrip,
                        fillsScreen: true, leadingInset: space.mapLeadingInset,
                        trust: JourneyTrust(card: card),
                        freshness: TripFreshness(
                            lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed
                        )
                    )
                    .id(trip.id)
                }
            }
            .overlay(alignment: .topLeading) {
                // One content position preserves its navigation and screen-owned sheets on fold.
                content(usesMapPanel)
                    .accessibilityIdentifier(usesMapPanel ? "journeyPlanSidePanel" : "journeyPlanScroll")
                    .frame(
                        width: usesMapPanel ? space.panelWidth : nil,
                        height: usesMapPanel ? space.maximumPanelHeight : nil,
                        alignment: .topLeading
                    )
                    .background {
                        if usesMapPanel { JourneyPanelSurface() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: usesMapPanel ? 30 : 0, style: .continuous))
                    .shadow(
                        color: Color.ttBackgroundBrand.opacity(usesMapPanel ? 0.16 : 0),
                        radius: 18, y: 6
                    )
                    .padding(usesMapPanel ? JourneyPanelGeometry.margin : 0)
            }
    }
}
