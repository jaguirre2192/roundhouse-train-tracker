import SwiftUI
import TrainTrackerCore

/// A screen opened from My Trips. Identity only, so the open trip survives the layout changing
/// under it: iPhone Duo folding between its outer (single stack) and inner (split view)
/// displays, an iPad resizing, or rotation.
enum TripsRoute: Hashable, Sendable {
    case journey(UUID)
    case train(RailIdentifier)
    /// Train search, opened from My Trips.
    case search
    /// Settings, opened from the button on My Trips.
    case settings
    /// Every finished journey, as stubs with their totals.
    case travelLog
    /// Saved journeys and trains whose travel dates have passed.
    case pastJourneys
}

/// The detail screen for a route, looked up from the current libraries so a removed journey or
/// train explains itself instead of showing stale content.
struct TripsRouteDestination: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(AppNavigationModel.self) private var navigation

    let route: TripsRoute

    var body: some View {
        destination
            // Removed while it was on screen (stop tracking, remove journey): go back. The
            // explanation below is for arriving at something already gone, from a link or widget.
            .onChange(of: subjectExists) { existed, exists in
                if existed, !exists { navigation.tripsPath.removeAll { $0 == route } }
            }
    }

    private var subjectExists: Bool {
        switch route {
        case let .journey(id): planLibrary.plans.contains { $0.id == id }
        case let .train(id): library.trip(id: id) != nil
        case .search, .settings, .travelLog, .pastJourneys: true
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case let .journey(id):
            if let plan = planLibrary.plans.first(where: { $0.id == id }) {
                JourneyPlanDetailView(plan: plan, planLibrary: planLibrary)
                    .id(plan.id)
            } else {
                unavailable("Journey no longer saved")
            }
        case .search:
            JourneySearchView(planLibrary: planLibrary)
        case .settings:
            TrainTrackerSettingsView()
        case .travelLog:
            TravelLogView()
        case .pastJourneys:
            JourneyHistoryView()
        case let .train(id):
            if let trip = library.trip(id: id) {
                // Route time zones come from the saved journeys inside the detail view.
                TripDetailView(trip: trip)
                    .id(trip.id)
            } else {
                unavailable("Train no longer tracked")
            }
        }
    }

    private func unavailable(_ title: String) -> some View {
        ContentUnavailableView(title, image: TrainTrackerSymbol.train,
            description: Text("Choose another trip from My Trips."))
            .trainTrackerPageBackground()
    }
}

extension EnvironmentValues {
    /// True inside the My Trips sidebar of the split view, where opening a trip replaces the
    /// detail column instead of pushing onto the sidebar.
    @Entry var isTripsSidebar = false
    /// Set on the compact My Trips stack, where a card zooms into the screen it opens.
    @Entry var tripsZoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Marks a My Trips card as the shape its screen zooms out of. Skipped for Reduce Motion,
    /// where the standard push is calmer.
    func tripsZoomSource(_ route: TripsRoute) -> some View {
        modifier(TripsZoomModifier(route: route, isSource: true))
    }

    /// The screen side of `tripsZoomSource`. A screen opened without a visible card, from a link
    /// or a widget, falls back to the standard push.
    func tripsZoomDestination(_ route: TripsRoute) -> some View {
        modifier(TripsZoomModifier(route: route, isSource: false))
    }
}

private struct TripsZoomModifier: ViewModifier {
    @Environment(\.tripsZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let route: TripsRoute
    let isSource: Bool

    func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            if isSource {
                content.matchedTransitionSource(id: route, in: namespace)
            } else {
                content.navigationTransition(.zoom(sourceID: route, in: namespace))
            }
        } else {
            content
        }
    }
}

/// Opens a My Trips route. In a stack it pushes; in the split view's sidebar it selects, so the
/// detail column and the stack read the same `AppNavigationModel.tripsPath` and a fold keeps
/// the open trip. The selected card in the sidebar is marked.
struct TripsRouteLink<Label: View>: View {
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.isTripsSidebar) private var isSidebar

    let route: TripsRoute
    /// Card links outline the selected card; a text button such as Open Journey does not.
    var marksSelection = true
    @ViewBuilder let label: () -> Label

    var body: some View {
        if isSidebar {
            let isSelected = marksSelection && navigation.tripsPath.first == route
            Button {
                navigation.open(route)
            } label: {
                label()
                    .overlay {
                        RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous)
                            .strokeBorder(Color.ttFocusRing, lineWidth: isSelected ? 2 : 0)
                    }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else if marksSelection {
            NavigationLink(value: route) { label().tripsZoomSource(route) }
        } else {
            NavigationLink(value: route, label: label)
        }
    }
}
