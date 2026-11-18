import MapKit
import SwiftUI
import TrainTrackerCore

/// Home without a saved train in focus: the map is still the screen. A running train is
/// drawn on it with its ticket, and one button follows it. If none can be found (offline, or
/// the small hours) the panel keeps the plain invitation to add a journey.
struct FirstRunHomeView<Notices: View, Footer: View>: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(JourneyIntakeModel.self) private var intake
    @Environment(AppNavigationModel.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.journeyReferenceDate) private var referenceDate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TrainTrackerPreference.mapStyle) private var mapStylePreference = MapStylePreference.muted

    let finder: FirstRunTrainFinder
    /// Saved actionable journeys own the panel before any suggested train.
    var showsSuggestion = true
    /// True when the rider has traveled before, so the words don't greet them as new.
    var isReturning = false
    /// Called with the train once it is tracked, so My Trips can bring it into focus.
    var followed: (TrainTrip) -> Void = { _ in }
    @ViewBuilder var notices: () -> Notices
    @ViewBuilder var footer: () -> Footer

    @State private var detent = JourneyDrawerDetent.half
    @State private var space = JourneyPanelGeometry()
    @State private var sideContentHeight: CGFloat?
    @State private var clock = Date.now
    @State private var followProblem: String?
    @State private var followCount = 0

    var body: some View {
        let date = referenceDate ?? clock
        let isDiscovering = showsSuggestion && scenePhase == .active
        let metrics = JourneyDrawerMetrics(contentHeight: space.height, bottomInset: space.bottom)
        Color.clear
            .onGeometryChange(for: JourneyPanelGeometry.self) { JourneyPanelGeometry($0) } action: { space = $0 }
            .background {
                map(at: date, metrics: metrics)
            }
            .overlay(alignment: space.floatsBeside ? .topLeading : .bottom) {
                if space.height > 0, space.floatsBeside {
                    sidePanel(at: date)
                } else if space.height > 0 {
                    JourneyDrawer(
                        detent: $detent, metrics: metrics,
                        scrollIdentifier: "firstRunPanelScroll",
                        accessibilityTitle: "Your journeys",
                        expansionHint: "Shows your journeys, imports and Calendar"
                    ) {
                        panelSummary(at: date)
                    } content: {
                        panelContent(at: date)
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: finder.featured?.trip.id)
            .task(id: isDiscovering ? finder.lookupRevision : nil) {
                guard isDiscovering else { return }
                clock = .now
                await finder.load(library: library, at: referenceDate ?? clock)
            }
            // A check that lands after the last tick must not read as being in the future.
            .onChange(of: finder.featured?.checkedAt) { clock = .now }
            .task(id: isDiscovering ? finder.featured?.trip.id : nil) {
                guard isDiscovering, finder.featured != nil else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    clock = .now
                    await finder.refresh(library: library)
                }
            }
            .sensoryFeedback(.success, trigger: followCount)
    }

    // MARK: Map

    @ViewBuilder
    private func map(at date: Date, metrics: JourneyDrawerMetrics) -> some View {
        if showsSuggestion, let featured = finder.featured {
            TripRouteMapView(
                trip: featured.trip, chrome: .compact,
                isRefreshing: finder.isRefreshing,
                refreshTrip: referenceDate == nil ? { Task { await finder.refresh(library: library) } } : nil,
                bottomInset: space.floatsBeside ? 0 : max(metrics.peek - space.bottom, 0),
                fillsScreen: true,
                obscuredBottom: space.floatsBeside ? 0 : max(metrics.mapInset(for: detent) - metrics.peek, 0),
                leadingInset: space.mapLeadingInset,
                trust: featured.trust(at: date),
                freshness: TripFreshness(lastSuccessfulCheck: featured.checkedAt, lastRefreshFailed: featured.refreshFailed)
            )
            .transition(.opacity)
        } else {
            // The rider's part of the world, waiting for a train to draw on it.
            Map(initialPosition: .region(MKCoordinateRegion(
                center: finder.hubs[0].coordinate,
                span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
            )))
            .mapStyle(mapStylePreference.mapStyle)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    // MARK: Panel

    private func sidePanel(at date: Date) -> some View {
        ScrollView {
            panelContent(at: date)
                .padding(.vertical, TrainTrackerSpacing.space16)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            sideContentHeight = height
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("firstRunPanelScroll")
        .frame(width: space.panelWidth, height: min(
            sideContentHeight ?? space.height,
            space.maximumPanelHeight
        ))
        .background { JourneyPanelSurface() }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Color.ttBackgroundBrand.opacity(0.16), radius: 18, y: 6)
        .padding(JourneyPanelGeometry.margin)
    }

    private func panelSummary(at date: Date) -> some View {
        let featured = showsSuggestion ? finder.featured : nil
        return HStack {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(featured?.title(at: date) ?? "Your journeys")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ttTextPrimary)
                Text(featured.map { LiveLineTicketPresentation.serviceName(for: $0.trip) } ?? "Journeys, tickets and Calendar")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            Spacer(minLength: TrainTrackerSpacing.space8)
            Image(systemName: "chevron.up")
                .foregroundStyle(Color.ttActionTint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, TrainTrackerSpacing.space16)
        .frame(maxWidth: .infinity, minHeight: 52)
    }

    private func panelContent(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            notices()
            if showsSuggestion {
                if let featured = finder.featured {
                    train(featured, at: date)
                } else {
                    invitation
                }
            }
            footer()
        }
        .padding(.horizontal, TrainTrackerSpacing.space16)
        .padding(.top, TrainTrackerSpacing.space4)
        .padding(.bottom, TrainTrackerSpacing.space4)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func train(_ featured: FirstRunTrainFinder.Featured, at date: Date) -> some View {
        let trip = featured.trip
        let zones = TripDetailTimeZoneContext(trip: trip, plans: planLibrary.plans)
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Text(featured.title(at: date))
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.ttTextPrimary)
                .accessibilityAddTraits(.isHeader)

            LiveLineTicket(
                trip: trip,
                density: .featured,
                routeTimeZones: zones.routeTimeZones,
                timeZoneIdentifier: { zones.timeZoneIdentifier(for: $0) },
                lastSuccessfulCheck: featured.checkedAt,
                lastRefreshFailed: featured.refreshFailed,
                referenceDate: date
            )
            .accessibilityIdentifier("firstRunTicket")

            VStack(spacing: 0) {
                Button {
                    follow(featured.trip)
                } label: {
                    Text("Follow This Train")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .trainTrackerPrimaryAction()
                .controlSize(.large)
                .buttonBorderShape(usesNarrowSideActions ? .roundedRectangle(radius: TrainTrackerRadius.group) : .capsule)
                .frame(maxWidth: usesNarrowSideActions ? 280 : .infinity)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("followFirstRunTrain")
                .accessibilityHint("Adds this train to My Trips. You can stop tracking it at any time.")

                Button("Add Your Own Journey") { intake.presentAddJourney() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("addJourneyEmptyState")
            }

            if let followProblem {
                Text(followProblem)
                    .font(.footnote)
                    .foregroundStyle(Color.ttTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usesNarrowSideActions: Bool { TrainTrackerDevice.isDuo && space.floatsBeside }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            if !isReturning && !dynamicTypeSize.isAccessibilitySize {
                RoundhouseWordmark(width: 140)
                    .foregroundStyle(Color.ttTextBrand)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(isReturning ? "No journeys right now" : "Your trains, live on a map")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.ttTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Add a journey from your ticket, Calendar or a train search to follow live times, platform changes and service alerts.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: TrainTrackerSpacing.space4) {
                Button {
                    intake.presentAddJourney()
                } label: {
                    Text("Add Journey")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .trainTrackerPrimaryAction()
                .controlSize(.large)
                .accessibilityIdentifier("addJourneyEmptyState")

                // The shortest way to a first tracked train when there is no ticket to hand.
                Button("Search for a Train") { navigation.open(.stations) }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("searchTrainEmptyState")
            }

            if finder.state == .looking {
                HStack(spacing: TrainTrackerSpacing.space8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for a train that’s running now…")
                        .font(.footnote)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            } else if finder.state == .unavailable {
                HStack(spacing: TrainTrackerSpacing.space8) {
                    Text("Featured train unavailable")
                        .foregroundStyle(Color.ttTextSecondary)
                    Button("Try Again") { finder.retry() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("retryFeaturedTrain")
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func follow(_ trip: TrainTrip) {
        do {
            try library.storeTrackedTrip(trip, watchingOnly: true)
            followProblem = nil
            followCount += 1
            followed(trip)
            // The stored copy has not been checked in this session yet; check it now so the
            // trust word stays where it was instead of dropping to Saved.
            if !LaunchFixtures.isActive {
                Task { await library.refreshTrackedTrip(id: trip.id) }
            }
        } catch {
            followProblem = "This train couldn’t be saved. \(error.localizedDescription)"
        }
    }
}
