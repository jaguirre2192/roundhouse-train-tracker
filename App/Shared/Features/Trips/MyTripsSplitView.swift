import SwiftUI
import TrainTrackerCore

/// My Trips on regular width (iPad, iPhone Duo's inner display): the trips list is the sidebar
/// and the selected trip fills the detail column. On compact width the app uses the single
/// My Trips stack instead, the same way a split view collapses on any iPhone.
struct MyTripsSplitView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(\.journeyReferenceDate) private var previewDate
    @Environment(AppNavigationModel.self) private var navigation
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isWide: Bool?
    /// Distance from the leading edge to a vertical fold (iPhone Duo open like a book), so the
    /// column divider sits on the crease and no card straddles it. Nil without one.
    @State private var creaseOffset: CGFloat?

    /// Below this width (iPad portrait) the sidebar steps aside so the detail keeps room for the
    /// ticket beside the map; at or above it (landscape) both show side by side.
    nonisolated static let sideBySideMinimumWidth: CGFloat = 1100

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AppSectionContent(section: .trips, isSelected: true, isSidebar: true)
                .environment(\.isTripsSidebar, true)
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { sidebarButton }
                }
                // Last, outside the toolbar modifiers: applied inside them, iPadOS ignores it and
                // squeezes the sidebar to about 320pt in portrait. On a folding display the
                // sidebar is exactly the width up to the crease.
                .navigationSplitViewColumnWidth(
                    min: creaseOffset ?? 380, ideal: creaseOffset ?? 420, max: creaseOffset ?? 440
                )
        } detail: {
            // The first route is the selection; anything deeper is pushed inside the detail.
            NavigationStack(path: detailPath) {
                if let selected = navigation.tripsPath.first {
                    TripsRouteDestination(route: selected)
                        .navigationDestination(for: TripsRoute.self) { TripsRouteDestination(route: $0) }
                } else {
                    defaultDetail
                        .navigationDestination(for: TripsRoute.self) { TripsRouteDestination(route: $0) }
                }
            }
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        // The system toggle sits on the sidebar's trailing edge, apart from Add; ours leads the
        // sidebar's controls. While the sidebar is hidden, detail screens show it on their leading
        // edge (trainTrackerShowSidebarButton), since a trip chosen in the sidebar replaces the
        // whole detail column and a toolbar here never reaches it.
        .toolbar(removing: .sidebarToggle)
        .environment(\.trainTrackerShowSidebar, columnVisibility == .detailOnly ? showSidebar : nil)
        // The wash runs up under the floating tabs, as on the other tabs, instead of the split
        // view's white container showing above the columns.
        .trainTrackerPageBackground()
        // Only crossing the width threshold changes the columns, so a sidebar the person opened
        // or closed by hand stays that way until the device is rotated.
        .onGeometryChange(for: CGFloat?.self) { Self.verticalCreaseOffset(in: $0) } action: { creaseOffset = $0 }
        // A vertical crease always gives each column its own half, whatever the total width.
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= Self.sideBySideMinimumWidth || Self.verticalCreaseOffset(in: proxy) != nil
        } action: { wide in
            guard wide != isWide else { return }
            isWide = wide
            columnVisibility = wide ? .all : .detailOnly
        }
    }

    /// The active fold's leading offset when it runs top to bottom through this view, from the
    /// system's division region (iOS 27.1). The fold's own width is left to the system.
    nonisolated static func verticalCreaseOffset(in proxy: GeometryProxy) -> CGFloat? {
        guard #available(iOS 27.1, *) else { return nil }
        let crease = proxy.reservedRegions(kind: .division).first {
            $0.isActive && $0.frame.height > $0.frame.width && $0.frame.minX > 0 && $0.frame.maxX < proxy.size.width
        }
        return crease.map { $0.frame.minX.rounded() }
    }

    /// Routes pushed inside the detail column, below the selection.
    private var detailPath: Binding<[TripsRoute]> {
        Binding(
            get: { Array(navigation.tripsPath.dropFirst()) },
            set: { navigation.tripsPath = Array(navigation.tripsPath.prefix(1)) + $0 }
        )
    }

    private func showSidebar() {
        withAnimation { columnVisibility = .all }
    }

    private var sidebarButton: some View {
        let isShowingSidebar = columnVisibility != .detailOnly
        return Button {
            withAnimation {
                columnVisibility = isShowingSidebar ? .detailOnly : .all
            }
        } label: {
            Label(isShowingSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading")
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    /// Current travel wins over future travel; saved journeys retain their passenger bounds.
    @ViewBuilder
    private var defaultDetail: some View {
        let date = previewDate ?? .now
        let presentation = JourneyPlanListPresentation(
            plans: planLibrary.plans,
            trips: library.trips,
            activeTrip: TripAutomaticRefreshPolicy.preferredActiveTrip(in: library.trips, at: date),
            at: date
        )
        let journey = JourneyHomeGuidance.select(plans: planLibrary.plans, trips: library.trips, at: date)
        let currentTrain = presentation.activeTrip.flatMap {
            RailJourneyProgress(trip: $0, referenceDate: date).phase == .underway ? $0 : nil
        } ?? presentation.currentTrains(asOf: date).first
        if let journey, journey.stage.direction.departure <= date {
            JourneyPlanDetailView(plan: journey.plan, planLibrary: planLibrary)
                // The default focus can change journey in place; a new identity rebuilds the
                // detail's per-journey state (its removal controller) for the new plan.
                .id(journey.plan.id)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("defaultJourneyDetail-\(journey.plan.id)")
        } else if let active = currentTrain {
            TripDetailView(trip: active, routeTimeZones: presentation.activeTripRouteTimeZones)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("defaultTripDetail-\(active.id.rawValue)")
        } else if let journey {
            JourneyPlanDetailView(plan: journey.plan, planLibrary: planLibrary)
                // The default focus can change journey in place; a new identity rebuilds the
                // detail's per-journey state (its removal controller) for the new plan.
                .id(journey.plan.id)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("defaultJourneyDetail-\(journey.plan.id)")
        } else if let next = presentation.activeTrip ?? presentation.upcomingTrains(asOf: date).first {
            TripDetailView(trip: next)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("defaultTripDetail-\(next.id.rawValue)")
        } else {
            ContentUnavailableView {
                Label("Choose a Trip", image: TrainTrackerSymbol.train)
            } description: {
                Text("Select a journey or train to see its live ticket, map and stops.")
            }
            .trainTrackerPageBackground()
            .trainTrackerShowSidebarButton()
        }
    }
}

extension EnvironmentValues {
    /// Set while the My Trips sidebar is hidden: shows it again. Nil everywhere else.
    @Entry var trainTrackerShowSidebar: (@MainActor () -> Void)?
}

extension View {
    /// Adds the Show Sidebar button to a My Trips detail screen's leading edge while the sidebar
    /// is hidden; does nothing on iPhone or while the sidebar shows.
    func trainTrackerShowSidebarButton() -> some View {
        modifier(ShowSidebarButtonModifier())
    }
}

private struct ShowSidebarButtonModifier: ViewModifier {
    @Environment(\.trainTrackerShowSidebar) private var showSidebar

    func body(content: Content) -> some View {
        content.toolbar {
            if let showSidebar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showSidebar) {
                        Label("Show Sidebar", systemImage: "sidebar.leading")
                    }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                }
            }
        }
    }
}
