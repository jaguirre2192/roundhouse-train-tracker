import SwiftUI

struct AppSectionContent: View {
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(AppNavigationModel.self) private var navigation

    let section: AppSection
    let isSelected: Bool
    var isSidebar = false

    var body: some View {
        switch section {
        case .trips:
            MyTripsView(isSidebar: isSidebar)
                .navigationDestination(item: Binding(
                    get: { navigation.requestedJourney },
                    set: { if $0 == nil { navigation.dismissJourney() } }
                )) { request in
                    JourneyNavigationDestination(request: request)
                }
                .navigationDestination(item: Binding(
                    get: { navigation.requestedJourneyPlanID },
                    set: { if $0 == nil { navigation.dismissJourneyPlan() } }
                )) { planID in
                    if let plan = planLibrary.plans.first(where: { $0.id == planID }) {
                        JourneyPlanDetailView(plan: plan, planLibrary: planLibrary)
                            // A new request can swap the plan without a new destination.
                            .id(plan.id)
                    } else {
                        ContentUnavailableView("Journey no longer saved", image: TrainTrackerSymbol.train,
                            description: Text("Choose another journey from My Trips."))
                    }
                }
        case .stations:
            JourneySearchView(planLibrary: planLibrary)
        case .map:
            if isSelected {
                RouteMapPlaceholderView(isSelected: true)
            } else {
                Color.ttBackgroundCanvas
            }
        case .settings:
            TrainTrackerSettingsView()
        }
    }
}
