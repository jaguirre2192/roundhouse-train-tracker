import SwiftUI
import TrainTrackerCore
import UIKit

struct MyTripsView: View {
  @Environment(TripLibrary.self) private var library
  @Environment(JourneyPlanLibrary.self) private var planLibrary
  @Environment(TicketInbox.self) private var ticketInbox
  @Environment(ForwardingStore.self) private var forwarding
  @Environment(AppNavigationModel.self) private var navigation
  @Environment(JourneyIntakeModel.self) private var intake
  @Environment(LocalJourneyTicketStore.self) private var ticketVault
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.journeyReferenceDate) private var previewDate
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  private var connectivity = ConnectivityMonitor.shared
  /// True in the regular-width split view, where My Trips is the sidebar and the selected trip
  /// opens in the detail column.
  var isSidebar = false
  @State private var isPresentingStorePreviewDetail = false
  @State private var isPresentingJourneyPreviewDetail = false
  /// The train chosen on the rail. Nil follows the automatic choice: the train underway now,
  /// otherwise the next to depart.
  @State private var selectedTripID: RailIdentifier?
  @State private var liveActivities = TrainLiveActivityManager.shared
  @State private var actionError: String?
  @State private var tripPendingRemoval: TrainTrip?
  @State private var shareItem: TripShareItem?
  @State private var travelLog = TravelLog.shared
  @State private var homeClock = Date.now
  /// How far the journey panel is pulled up over the map.
  @State private var drawerDetent = JourneyDrawerDetent.half
  /// Finds a train that is running now to show someone with no journeys.
  @State private var firstRun = FirstRunTrainFinder()

  var body: some View {
    chrome(root)
  }

  private var root: some View {
    // One clock decides whether a train leads the screen as its map, and which one. It is plain
    // state, not a timeline view, so nothing stands between the map and the screen's edges.
    let date = previewDate ?? homeClock
    let savedFocus = JourneyHomeGuidance.select(plans: planLibrary.plans, trips: library.trips, at: date)
    let hasOtherTrains = !JourneyPlanListPresentation(
      plans: planLibrary.plans, trips: library.trips, activeTrip: nil, at: date
    ).otherTrains(asOf: date).isEmpty
    return Group {
      if let trip = mapHomeTrip(at: date) {
        mapHome(trip, at: date)
      } else if showsDiscoveryHome {
        FirstRunHomeView(
          finder: firstRun, showsSuggestion: savedFocus == nil && !hasOtherTrains, isReturning: !travelLog.entries.isEmpty || !library.trips.isEmpty || !planLibrary.plans.isEmpty,
          followed: { selectedTripID = $0.id }
        ) {
          notices
        } footer: {
          journeyContent(at: date, includesEmptyState: false)
        }
      } else {
        listHome
      }
    }
    .task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        homeClock = .now
      }
    }
    .trainTrackerPageBackground(mood: pageMood)
    .navigationTitle("My Trips")
    .navigationBarTitleDisplayMode(.inline)
    .trainTrackerBarTitleHidden(usesColumnTitle || (usesNativeBar && usesCompactHeader))
    // On iPhone Duo the bar is only its buttons in the side strip: no title band over the map.
    .toolbarBackgroundVisibility(usesNativeBar && usesCompactHeader ? .hidden : .automatic, for: .navigationBar)
    // Compact width has no navigation bar: a slim pinned header carries the rail (or the title
    // when there is no train) and the buttons, so the map or the list starts at the top.
    // iPhone Duo keeps the system's own bar, which sits in the strip beside the camera; only
    // the trains float over the map there.
    .toolbar(usesCompactHeader && !usesNativeBar ? .hidden : .automatic, for: .navigationBar)
    .myTripsTopBar(isEnabled: usesCompactHeader && (!usesNativeBar || mapHomeTrip(at: previewDate ?? .now) != nil), isPanel: mapHomeTrip(at: previewDate ?? .now) != nil || showsDiscoveryHome) { compactHeader }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      JourneyIntakeUndoBanner()
        .padding(.bottom, TrainTrackerSpacing.space8)
    }
  }

  /// The train that leads My Trips as its map: the one chosen on the rail, otherwise the one
  /// underway or next to leave. Compact width only; a sidebar or a wide column keeps the list.
  private func mapHomeTrip(at date: Date) -> TrainTrip? {
    guard usesCompactHeader else { return nil }
    let rail = railState(focusTripIDs: focusTripIDs(at: date), at: date)
    let journey = JourneyHomeGuidance.select(plans: planLibrary.plans, trips: library.trips, at: date)
    return rail.chosenTrip ?? rail.presentation.activeTrip ?? journey?.stage.focusTrip
  }

  private func focusTripIDs(at date: Date) -> Set<RailIdentifier> {
    let focus = JourneyHomeGuidance.select(plans: planLibrary.plans, trips: library.trips, at: date)
    return focus.map { Set($0.plan.outbound.childTripIDs + ($0.plan.returnDirection?.childTripIDs ?? [])) } ?? []
  }

  /// History and unfinished imports belong in the panel; they never replace the map.
  private var showsDiscoveryHome: Bool { usesCompactHeader }

  /// The train's map fills the screen; its journey, then every other trip, rests over it.
  private func mapHome(_ trip: TrainTrip, at date: Date) -> some View {
    let focus = JourneyHomeGuidance.select(plans: planLibrary.plans, trips: library.trips, at: date)
    let segment = focus?.stage.focusTrip?.id == trip.id
      ? focus?.stage.focusSegment
      : JourneyTripContext.selectedSegment(for: trip.id, plans: planLibrary.plans)
    return MapBackedJourneyView(
      trip: trip, selectedSegment: segment,
      detent: $drawerDetent
    ) {
      notices
    } actions: {
      JourneyActionRow(
        shareURL: nil, shareSubject: "\(trip.product) train trip",
        share: { share(trip) }, stopTracking: { tripPendingRemoval = trip }
      )
    } extra: {
      journeyContent(at: date, leadingTripID: trip.id)
    }
    // A new ticket waits to print until nothing is in front of My Trips.
    .environment(\.ticketCanPrint, navigation.tripsPath.isEmpty && intake.presentation == nil)
  }

  private var listHome: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
        // On regular width the content is a centred column; the title joins it so title and
        // tickets share one leading edge instead of the title hugging the screen edge.
        if usesColumnTitle {
          Text("My Trips")
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(Color.ttTextPrimary)
            .accessibilityAddTraits(.isHeader)
        }

        notices

        // One 30-second clock decides the "now" focus and what the lists below may omit, so
        // the same journey or train is never shown twice.
        TimelineView(.periodic(from: .now, by: 30)) { context in
          journeyContent(at: previewDate ?? context.date)
        }
      }
      .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
      .padding(LayoutMetrics.pageInset)
      .padding(.bottom, TrainTrackerSpacing.space32)
      .frame(maxWidth: .infinity)
    }
    .refreshable {
      await library.refreshTrackedTrips()
      if ReleaseFeatures.gmailImportEnabled { await ticketInbox.refresh() }
      await forwarding.refresh()
    }
  }

  /// Alerts, dialogs, polling and the bar buttons, shared by the map and the list.
  private func chrome(_ content: some View) -> some View {
    content
    .alert(
      "Shared Trip",
      isPresented: Binding(
        get: { library.shareImportMessage != nil },
        set: { if !$0 { library.dismissShareImportMessage() } }
      )
    ) {
      Button("OK") { library.dismissShareImportMessage() }
    } message: {
      Text(library.shareImportMessage ?? "")
    }
    .alert("Couldn’t Complete That", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK") { actionError = nil }
    } message: {
      Text(actionError ?? "")
    }
    .confirmationDialog(
      "Stop tracking this train?",
      isPresented: Binding(get: { tripPendingRemoval != nil }, set: { if !$0 { tripPendingRemoval = nil } }),
      titleVisibility: .visible,
      presenting: tripPendingRemoval
    ) { trip in
      Button("Stop Tracking", role: .destructive) {
        if library.removeTrip(id: trip.id) {
          if selectedTripID == trip.id { selectedTripID = nil }
        } else {
          actionError = "The train is still tracked. Try again."
        }
      }
    } message: { _ in
      Text("The trip will be removed and change notifications will stop. Any journey group that includes it will remain and show “No longer tracked.”")
    }
    .sheet(item: $shareItem) { item in
      TripShareSheet(item: item)
        .presentationDetents([.medium, .large])
    }
    // Polls only while the scene is active; leaving restarts the task, and a cancelled sleep
    // ends the loop rather than running one more refresh on the way out.
    .task(id: scenePhase == .active) {
      guard scenePhase == .active else { return }
      await library.refreshIfNeeded()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        await library.refreshTrackedTrips()
      }
    }
    .onChange(of: library.trips, initial: true) {
      recordFinishedJourneys()
      if previewDate == nil, !LaunchFixtures.isActive, !library.tripArchiveRecoveryRequired {
        StopWakeAlerts.shared.sync(with: library.trips)
      }
    }
    .onChange(of: library.watchingOnlyIDs) { recordFinishedJourneys() }
    .onChange(of: connectivity.isOffline) { wasOffline, isOffline in
      guard wasOffline, !isOffline, scenePhase == .active else { return }
      Task { await library.refreshTrackedTrips() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active,
         library.pushDeliveryWarningReason == .authorizationDenied {
        library.resumePushWatches()
      }
    }
    .toolbar {
      // In the sidebar it sits on the leading side, beside the sidebar button, like the other
      // sidebar controls; elsewhere it is the screen's primary action.
      if usesCompactHeader, usesNativeBar {
        // The same three actions as the floating buttons, in the system's bar.
        ToolbarItem(placement: .primaryAction) {
          Button {
            navigation.open(TripsRoute.search)
          } label: {
            Label("Search Trains", systemImage: "magnifyingglass")
          }
          .accessibilityIdentifier("searchTrainsFromTrips")
          .accessibilityHint("Finds a train by route, date and time")
        }
      }
      if !usesCompactHeader || usesNativeBar {
        ToolbarItem(placement: isSidebar ? .topBarLeading : .primaryAction) {
          // The single entry point for adding: tickets, Calendar, forwarding and train search.
          Button {
            intake.presentAddJourney()
          } label: {
            Label("Add Journey", systemImage: "plus")
          }
          .keyboardShortcut("n", modifiers: .command)
          .accessibilityIdentifier("addJourneyFromTrips")
          .accessibilityHint("Add from a ticket photo, PDF, pasted text, Calendar, a forwarded email or a train search")
        }
        ToolbarItem(placement: isSidebar ? .topBarLeading : .primaryAction) {
          Button {
            navigation.open(TripsRoute.settings)
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
          .accessibilityIdentifier("settingsFromTrips")
        }
      }
    }
    .navigationDestination(isPresented: $isPresentingStorePreviewDetail) {
      if let trip = library.activeTrip {
        TripDetailView(trip: trip)
      }
    }
    .navigationDestination(isPresented: $isPresentingJourneyPreviewDetail) {
      if let plan = journeyPreviewPlan {
        JourneyPlanDetailView(plan: plan, planLibrary: planLibrary)
      }
    }
    .task {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AppStorePreviewDetail") {
          isPresentingStorePreviewDetail = true
        }
        if ProcessInfo.processInfo.arguments.contains("-JourneyPlanPreviewDetail") {
          isPresentingJourneyPreviewDetail = true
        }
      #endif
    }
  }

  /// - Parameter leadingTripID: the train already shown as the map and its panel, which the
  ///   list then leaves out.
  @ViewBuilder
  private func journeyContent(at date: Date, leadingTripID: RailIdentifier? = nil, includesEmptyState: Bool = true) -> some View {
    let focus = JourneyHomeGuidance.select(plans: planLibrary.plans, trips: library.trips, at: date)
    let focusTripIDs = focus.map { Set($0.plan.outbound.childTripIDs + ($0.plan.returnDirection?.childTripIDs ?? [])) } ?? []
    let rail = railState(focusTripIDs: focusTripIDs, at: date)
    let railTrips = rail.trips
    let chosenTrip = rail.chosenTrip
    let presentation = rail.presentation
    let currentJourneys = presentation.currentJourneys(asOf: date).filter { $0.plan.id != focus?.plan.id }
    let upcomingJourneys = presentation.upcomingJourneys(asOf: date).filter { $0.plan.id != focus?.plan.id }
    let pastJourneys = presentation.pastJourneys(asOf: date).filter { $0.plan.id != focus?.plan.id }
    let currentIndividualTrips = presentation.currentTrains(asOf: date)
    let upcomingIndividualTrips = presentation.upcomingTrains(asOf: date)
    let otherIndividualTrips = presentation.otherTrains(asOf: date)
    let pastIndividualTrips = presentation.pastTrains(asOf: date)

    VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
      // Regular width keeps the rail in the column; compact width pins it in the header.
      if usesColumnTitle, !isSidebar {
        JourneyRail(
          items: railTrips.map { railItem(for: $0, at: date) },
          selection: presentation.activeTrip?.id,
          select: { selectedTripID = $0 }
        )
      }

      // A train chosen on the rail leads the page whatever its phase.
      if let chosenTrip, presentation.activeTrip?.id == chosenTrip.id, chosenTrip.id != leadingTripID {
        highlightedTrain(chosenTrip, presentation: presentation, at: date)
      }

      if let focus, focus.stage.direction.departure <= date {
        JourneyHomeFocusView(focus: focus, referenceDate: date, trainAlreadyVisible: focus.stage.focusTrip?.id == leadingTripID)
      }

      if chosenTrip == nil,
         let activeTrip = presentation.activeTrip,
         !focusTripIDs.contains(activeTrip.id), activeTrip.id != leadingTripID,
         RailJourneyProgress(trip: activeTrip, referenceDate: date).phase == .underway {
        highlightedTrain(activeTrip, presentation: presentation, at: date)
      }
      journeySection(title: JourneySearchCopy.Plan.currentJourneys, journeys: currentJourneys)
      individualTrainSection(title: JourneySearchCopy.Plan.currentTrains, trips: currentIndividualTrips)

      if let focus, focus.stage.direction.departure > date {
        JourneyHomeFocusView(focus: focus, referenceDate: date, trainAlreadyVisible: focus.stage.focusTrip?.id == leadingTripID)
      }
      if chosenTrip == nil,
         let activeTrip = presentation.activeTrip,
         !focusTripIDs.contains(activeTrip.id), activeTrip.id != leadingTripID,
         RailJourneyProgress(trip: activeTrip, referenceDate: date).phase != .underway {
        highlightedTrain(activeTrip, presentation: presentation, at: date)
      }
      journeySection(title: JourneySearchCopy.Plan.upcomingJourneys, journeys: upcomingJourneys)

      individualTrainSection(title: JourneySearchCopy.Plan.upcomingTrains, trips: upcomingIndividualTrips)
      individualTrainSection(title: JourneySearchCopy.Plan.otherTrains, trips: otherIndividualTrips)

      unfinishedImports

      // Upcoming imports belong ahead of completed journey history.
      TicketPurchaseSavedSection()

      if ReleaseFeatures.gmailImportEnabled, !ticketInbox.tickets.isEmpty {
        tripSection(title: JourneySearchCopy.Plan.fromYourInbox) {
          LazyVStack(spacing: TrainTrackerSpacing.space12) {
            ForEach(ticketInbox.tickets) { ticket in
              NavigationLink {
                TrainTicketDetailView(ticket: ticket, artifactSource: ticketInbox)
              } label: {
                TrainTicketRow(ticket: ticket)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

      if !forwarding.tickets.isEmpty {
        tripSection(title: JourneySearchCopy.Plan.forwardedTickets) {
          LazyVStack(spacing: TrainTrackerSpacing.space12) {
            if let issue = forwarding.refreshIssue {
              TrainTrackerNotice(
                "Forwarded tickets weren’t updated",
                message: "\(issue) Tickets already received are shown.",
                systemImage: "wifi.exclamationmark"
              )
            }
            ForEach(forwarding.tickets) { ticket in
              NavigationLink {
                TrainTicketDetailView(
                  ticket: ticket,
                  artifactSource: forwarding,
                  onDelete: {
                    if await forwarding.deleteTicket(id: ticket.id) { return nil }
                    defer { forwarding.dismissError() }
                    return forwarding.errorMessage ?? "The ticket couldn't be deleted. Try again."
                  }
                )
              } label: {
                TrainTicketRow(ticket: ticket)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

      CalendarSuggestionsSection(referenceDate: date) { candidate in
        intake.review(suggestion: candidate.routeSuggestion)
      }

      if !pastJourneys.isEmpty || !pastIndividualTrips.isEmpty || !travelLog.entries.isEmpty {
        JourneyHistoryLink(count: pastJourneys.filter { !JourneyHistoryArchive.isWatchOnly($0.plan, watching: library.watchingOnlyIDs) }.count
                           + pastIndividualTrips.filter { !library.isWatchingOnly($0.id) }.count)
      }

      if includesEmptyState, library.trips.isEmpty, planLibrary.plans.isEmpty, !library.isRefreshing,
         ticketVault.draftTickets.isEmpty, ticketVault.reviews.isEmpty {
        emptyState
      }
    }
  }

  /// The focused train: its ticket and headline open the journey; beneath them sit any service
  /// alert, the one action that matters now, and the facts, each of which opens its own answer.
  /// In the sidebar the compact ticket carries the facts itself.
  private func highlightedTrain(_ trip: TrainTrip, presentation: JourneyPlanListPresentation, at date: Date) -> some View {
    let routeTimeZones = presentation.activeTripRouteTimeZones
    let zones = TripDetailTimeZoneContext(trip: trip, routeTimeZones: routeTimeZones, plans: planLibrary.plans)
    let segment = JourneyTripContext.selectedSegment(for: trip.id, plans: planLibrary.plans)
    let card = ActiveTripCardPresentation(
      trip: trip, routeTimeZones: routeTimeZones, referenceDate: date,
      lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
      lastRefreshFailed: library.lastRefreshFailed(for: trip.id),
      selectedSegment: segment
    )
    let stationMapURL = JourneyExperiencePresentation(
      trip: trip, timeZones: zones, referenceDate: date,
      lastSuccessfulCheck: card.lastSuccessfulCheck, refreshFailed: card.lastRefreshFailed,
      selectedSegment: segment
    ).stationMapURL
    let action = JourneyPhaseAction.resolve(
      trip: trip, progress: card.effectiveProgress,
      canStartLiveActivity: canStartLiveActivity(for: trip, segment: segment, at: date),
      stationMapURL: stationMapURL
    )
    return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space20) {
      TripsRouteLink(route: .train(trip.id)) {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space20) {
          liveTicket(for: trip, routeTimeZones: routeTimeZones, at: date, showsFacts: isSidebar)
          if !isSidebar {
            TripInsightHeadline(presentation: card, timeZoneIdentifier: { zones.timeZoneIdentifier(for: $0) })
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("highlightedTrain-\(trip.id.rawValue)")
      .accessibilityHint("Opens live trip details")

      if !isSidebar {
        if let alert = trip.alerts.first {
          DisruptionBanner(alert: alert)
        }
        JourneyPhaseActionButton(action: action, isBusy: liveActivities.isBusy) {
          perform($0, for: trip, segment: segment)
        }
        TripFactGrid(presentation: card, timeZoneIdentifier: { zones.timeZoneIdentifier(for: $0) }) { fact in
          switch fact {
          case .nextStop, .status: navigation.open(.train(trip.id))
          case .platform: if let stationMapURL { openURL(stationMapURL) } else { navigation.open(.train(trip.id)) }
          case .arrival: openLiveMap(for: trip)
          }
        }
      }
    }
  }

  /// A tracked train that has arrived leaves a stub in the Travel Log: the stops the rider was
  /// on board for, once, however many times it is seen afterwards.
  private func recordFinishedJourneys() {
    guard previewDate == nil else { return }
    travelLog.recordFinishedRides(in: library, plans: planLibrary.plans, at: .now)
  }

  // MARK: Actions

  /// A Live Activity can start when none is running, the system allows them and this train is
  /// within its window. Preview clocks never start one.
  private func canStartLiveActivity(for trip: TrainTrip, segment: JourneyPlanSegment?, at date: Date) -> Bool {
    guard previewDate == nil, liveActivities.areActivitiesEnabled, liveActivities.activeAttributes == nil else { return false }
    let selection = TrainLiveActivitySelection(trip: trip, segment: segment, plans: planLibrary.plans)
    return selection?.projection(
      at: date, checkedAt: library.lastSuccessfulCheck(for: trip.id),
      refreshFailed: library.lastRefreshFailed(for: trip.id)
    ).eligibility == .available
  }

  private func perform(_ action: JourneyPhaseAction, for trip: TrainTrip, segment: JourneyPlanSegment?) {
    switch action {
    case .showOnLockScreen:
      liveActivities.connect(library: library, plans: planLibrary)
      Task {
        do { try await liveActivities.start(tripID: trip.id, segment: segment) }
        catch is CancellationError { return }
        catch { actionError = error.localizedDescription }
      }
    case let .stationMap(url): openURL(url)
    case .liveMap: openLiveMap(for: trip)
    case .findAnotherTrain:
      if let request = JourneyHomeGuidance.alternatives(for: trip, segment: segment, at: previewDate ?? .now) {
        navigation.openTicketJourneySearch(request)
      } else {
        navigation.open(.stations)
      }
    case .viewJourney: navigation.open(.train(trip.id))
    }
  }

  /// The Map tab remembers its train in scene storage; set it, then go there.
  private func openLiveMap(for trip: TrainTrip) {
    navigation.open(.train(trip.id))
  }

  private func share(_ trip: TrainTrip) {
    Task {
      do {
        let url = try await library.shareURL(for: trip)
        shareItem = TripShareItem(url: url, subject: "\(trip.product) train trip")
      } catch is CancellationError {
        return
      } catch {
        actionError = "Roundhouse couldn’t create a share link. Check your connection, then try again."
      }
    }
  }

  private func railPreview(for id: RailIdentifier, at date: Date) -> some View {
    Group {
      if let trip = library.trip(id: id) {
        liveTicket(for: trip, routeTimeZones: nil, at: date)
          .frame(width: 320)
          .padding(TrainTrackerSpacing.space12)
      }
    }
  }

  @ViewBuilder
  private func railMenu(for id: RailIdentifier) -> some View {
    if let trip = library.trip(id: id) {
      Button("Open Journey", systemImage: "arrow.right") { navigation.open(.train(id)) }
      Button("Open Live Map", systemImage: "location.viewfinder") { openLiveMap(for: trip) }
      Button("Share Trip", systemImage: "square.and.arrow.up") { share(trip) }
      Divider()
      Button("Stop Tracking", systemImage: "trash", role: .destructive) { tripPendingRemoval = trip }
    }
  }

  @ViewBuilder
  private func journeySection(title: String, journeys: [JourneyPlanPresentation]) -> some View {
    if !journeys.isEmpty {
      tripSection(title: title) {
        LazyVStack(spacing: TrainTrackerSpacing.space12) {
          ForEach(journeys) { journey in
            TripsRouteLink(route: .journey(journey.plan.id)) {
              TicketStubCard(content: TicketStubCardContent(journey: journey))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens journey details")
          }
        }
      }
    }
  }

  @ViewBuilder
  private func individualTrainSection(title: String, trips: [TrainTrip]) -> some View {
    if !trips.isEmpty {
      tripSection(title: title) {
        LazyVStack(spacing: TrainTrackerSpacing.space12) {
          ForEach(trips) { trip in
            TripsRouteLink(route: .train(trip.id)) {
              TicketStubCard(content: TicketStubCardContent(
                trip: trip,
                routeTimeZones: TripDetailTimeZoneContext(trip: trip, plans: planLibrary.plans).routeTimeZones
              ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("individualTrain-\(trip.id.rawValue)")
            .accessibilityHint("Opens train details")
          }
        }
      }
    }
  }

  /// The live trip as the ink Line Ticket, with coach and seat from a linked saved ticket.
  private func liveTicket(
    for trip: TrainTrip, routeTimeZones: JourneyPlanRouteTimeZones?, at date: Date, showsFacts: Bool = true
  ) -> some View {
    let zones = TripDetailTimeZoneContext(trip: trip, routeTimeZones: routeTimeZones, plans: planLibrary.plans)
    let seat = ticketVault.tickets(forTrip: trip.id.rawValue).first { $0.details.coach != nil && $0.details.seat != nil }
    return LiveLineTicket(
      trip: trip,
      density: isSidebar ? .compact : .full,
      routeTimeZones: routeTimeZones,
      timeZoneIdentifier: { zones.timeZoneIdentifier(for: $0) },
      lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
      lastRefreshFailed: library.lastRefreshFailed(for: trip.id),
      selectedSegment: JourneyTripContext.selectedSegment(for: trip.id, plans: planLibrary.plans),
      coach: seat?.details.coach,
      seat: seat?.details.seat,
      referenceDate: date,
      showsFacts: showsFacts
    )
  }

  // MARK: Compact header

  /// A phone in compact width, where the pinned header replaces the navigation bar.
  private var usesCompactHeader: Bool { !usesColumnTitle }
  /// True on iPhone Duo, where the system's bar has a place of its own beside the camera.
  private var usesNativeBar: Bool { TrainTrackerDevice.isDuo }

  private var compactHeader: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let date = previewDate ?? context.date
      let mapTrip = mapHomeTrip(at: date)
      let items = mapTrip.map { railItems(leading: $0, at: date) } ?? []
      HStack(spacing: TrainTrackerSpacing.space8) {
        if let mapTrip {
          // Over the map the rail names the train in focus, even when it is the only one.
          JourneyRail(
            items: items,
            selection: mapTrip.id,
            select: { selectedTripID = $0 },
            maxEqualWidthItems: 2,
            minimumItems: 1,
            isOverMap: true,
            chipCornerRadius: TrainTrackerRadius.full,
            preview: { id in AnyView(railPreview(for: id, at: date)) },
            menu: { id in AnyView(railMenu(for: id)) }
          )
          // Chips fade out before the header buttons instead of sliding under them. The
          // padding keeps each chip's glass and shadow inside the mask.
          .padding(.vertical, TrainTrackerSpacing.space12)
          .mask {
            HStack(spacing: 0) {
              Rectangle()
              LinearGradient(colors: [.black, items.count > 2 ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: TrainTrackerSpacing.space20)
            }
          }
          .padding(.vertical, -TrainTrackerSpacing.space12)
          if items.count == 1 { Spacer(minLength: TrainTrackerSpacing.space8) }
        } else if showsDiscoveryHome {
          // Over the first-run map only the buttons float; the panel below does the talking.
          Spacer(minLength: 0)
        } else {
          VStack(alignment: .leading, spacing: 1) {
            Text("My Trips")
              .font(.title3.weight(.bold))
              .foregroundStyle(Color.ttTextPrimary)
              .accessibilityAddTraits(.isHeader)
            liveDataFreshness
          }
          Spacer(minLength: TrainTrackerSpacing.space8)
        }
        if usesNativeBar {
          // The actions are in the system's bar.
          EmptyView()
        } else if items.count > 1 {
          // Several trains need the row for themselves, so the three actions share one button.
          headerMenu
        } else {
          headerButtons
        }
      }
      .myTripsHeaderGlassContainer()
      // Over the map there is no bar: each pill and button floats on its own, and the map
      // shows between them. They share one height, so every end is the same full round.
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, mapTrip == nil && !showsDiscoveryHome ? LayoutMetrics.pageInset : TrainTrackerSpacing.space16)
      .padding(.vertical, TrainTrackerSpacing.space8)
      .environment(\.myTripsHeaderFloats, mapTrip != nil || showsDiscoveryHome)
    }
  }

  @ViewBuilder
  private var headerButtons: some View {
    Button {
      navigation.open(TripsRoute.search)
    } label: {
      Image(systemName: "magnifyingglass")
        .font(.body.weight(.semibold))
        .frame(width: 28, height: 28)
    }
    .myTripsCircleButton(tint: nil)
    .tripsZoomSource(.search)
    .accessibilityLabel("Search Trains")
    .accessibilityIdentifier("searchTrainsFromTrips")
    .accessibilityHint("Finds a train by route, date and time")
    Button {
      intake.presentAddJourney()
    } label: {
      Image(systemName: "plus")
        .font(.body.weight(.semibold))
        .frame(width: 28, height: 28)
    }
    .myTripsCircleButton(tint: pageMood.glassTint)
    .keyboardShortcut("n", modifiers: .command)
    .accessibilityLabel("Add Journey")
    .accessibilityIdentifier("addJourneyFromTrips")
    .accessibilityHint("Add from a ticket photo, PDF, pasted text, Calendar, a forwarded email or a train search")
    Button {
      navigation.open(TripsRoute.settings)
    } label: {
      Image(systemName: "gearshape")
        .font(.body.weight(.semibold))
        .frame(width: 28, height: 28)
    }
    .myTripsCircleButton(tint: nil)
    .accessibilityLabel("Settings")
    .accessibilityIdentifier("settingsFromTrips")
    .accessibilityHint("Alerts, appearance, account and data sources")
  }

  private var headerMenu: some View {
    Menu {
      Button("Add Journey", systemImage: "plus") { intake.presentAddJourney() }
        .accessibilityIdentifier("addJourneyFromTrips")
      Button("Search Trains", systemImage: "magnifyingglass") { navigation.open(TripsRoute.search) }
        .accessibilityIdentifier("searchTrainsFromTrips")
      Button("Settings", systemImage: "gearshape") { navigation.open(TripsRoute.settings) }
        .accessibilityIdentifier("settingsFromTrips")
    } label: {
      Image(systemName: "ellipsis")
        .font(.body.weight(.semibold))
        .frame(width: 28, height: 28)
    }
    .myTripsCircleButton(tint: nil)
    .accessibilityLabel("More")
    .accessibilityIdentifier("moreFromTrips")
    .accessibilityHint("Add a journey, search trains or open Settings")
  }

  /// The rail over the map: the leading train first if the rail would otherwise omit it (a
  /// train inside a saved journey), then every standalone train underway or still to leave.
  private func railItems(leading trip: TrainTrip, at date: Date) -> [JourneyRailItem] {
    let rail = railState(focusTripIDs: focusTripIDs(at: date), at: date)
    let trips = rail.trips.contains { $0.id == trip.id } ? rail.trips : [trip] + rail.trips
    return trips.map { railItem(for: $0, at: date) }
  }

  // MARK: Rail and mood

  private struct RailState {
    let trips: [TrainTrip]
    let chosenTrip: TrainTrip?
    let presentation: JourneyPlanListPresentation
  }

  /// The rail offers every standalone train that is underway or still to depart. Choosing one
  /// makes it the highlighted train; the lists below then carry the others.
  private func railState(focusTripIDs: Set<RailIdentifier>, at date: Date) -> RailState {
    let automatic = JourneyPlanListPresentation(
      plans: planLibrary.plans,
      trips: library.trips,
      activeTrip: TripAutomaticRefreshPolicy.preferredActiveTrip(in: library.trips, at: date),
      at: date
    )
    let trips = Self.railTrips(in: automatic, excluding: focusTripIDs, at: date)
    let chosen = selectedTripID.flatMap { id in trips.first { $0.id == id } }
    let presentation = chosen.map {
      JourneyPlanListPresentation(plans: planLibrary.plans, trips: library.trips, activeTrip: $0, at: date)
    } ?? automatic
    return RailState(trips: trips, chosenTrip: chosen, presentation: presentation)
  }

  /// Standalone trains that are underway or still to depart, in departure order so chips keep
  /// their places when the selection changes.
  private static func railTrips(
    in presentation: JourneyPlanListPresentation, excluding focusTripIDs: Set<RailIdentifier>, at date: Date
  ) -> [TrainTrip] {
    let trips = [presentation.activeTrip].compactMap { $0 }
      + presentation.currentTrains(asOf: date) + presentation.upcomingTrains(asOf: date)
    return trips
      .filter { !focusTripIDs.contains($0.id) }
      .map { (trip: $0, departure: RailJourneyProgress(trip: $0, referenceDate: date).departureDate ?? .distantFuture) }
      .sorted { $0.departure < $1.departure }
      .map(\.trip)
  }

  private func railItem(for trip: TrainTrip, at date: Date) -> JourneyRailItem {
    let zones = TripDetailTimeZoneContext(trip: trip, plans: planLibrary.plans)
    let card = ActiveTripCardPresentation(
      trip: trip, routeTimeZones: zones.routeTimeZones, referenceDate: date,
      lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
      lastRefreshFailed: library.lastRefreshFailed(for: trip.id)
    )
    let progress = card.effectiveProgress
    let codes = [card.originCode ?? card.originName, card.destinationCode ?? card.destinationName]
    let isConfirmed = TripFreshness(
      lastSuccessfulCheck: card.lastSuccessfulCheck, lastRefreshFailed: card.lastRefreshFailed
    ).isConfirmed
    // Before departure the chip says when it leaves, counting down the last half hour on its
    // ring; from then on it says how the train is running and the ring fills with the journey.
    var detail = card.detailStatusValue
    var ring: Double?
    let minutesToDeparture = card.departureDate.map { Int(($0.timeIntervalSince(date) / 60).rounded(.up)) }
    if card.isBeforeBoarding, let minutes = minutesToDeparture, minutes > 0, minutes <= 30 {
      detail = "In \(minutes) min"
      ring = 1 - Double(minutes) / 30
    } else if card.isBeforeBoarding, let departure = card.departureDate {
      // The departure station's own zone, as the train lists use.
      let zone = zones.routeTimeZones?.departureTimeZoneIdentifier
        ?? trip.stopTimes.first.flatMap { zones.timeZoneIdentifier(for: $0) }
        ?? TimeZone.autoupdatingCurrent.identifier
      var weekday = Date.FormatStyle.dateTime.weekday(.abbreviated)
      weekday.timeZone = TimeZone(identifier: zone) ?? .autoupdatingCurrent
      detail = "\(departure.formatted(weekday)) \(JourneyPlanDateTimePresentation.time(departure, timeZoneIdentifier: zone))"
    }
    if progress.phase == .underway, let start = progress.departureDate, let end = progress.arrivalDate, end > start {
      ring = min(max(date.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }
    return JourneyRailItem(
      id: trip.id,
      route: codes.joined(separator: " → "),
      detail: detail,
      tint: card.status.kind.isDisruption && isConfirmed ? card.status.color : .ttRouteActive,
      tintOnInk: card.status.kind.isDisruption && isConfirmed ? TicketStatusBadge.color(for: card.status.kind) : .ttRouteOnInk,
      trust: JourneyTrust(card: card),
      progress: ring,
      statusKey: "\(card.status.kind)|\(card.status.delayMinutes)|\(trip.isCancelled)"
    )
  }

  /// The mood of the train My Trips leads with; calm when there is none.
  private var pageMood: JourneyMood {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      if let index = arguments.firstIndex(of: "-JourneyMoodPreview"), arguments.indices.contains(index + 1),
         let mood = JourneyMood(rawValue: arguments[index + 1]) {
        return mood
      }
    #endif
    guard !isSidebar else { return .calm }
    let date = previewDate ?? .now
    let trip = selectedTripID.flatMap { id in library.trips.first { $0.id == id } }
      ?? TripAutomaticRefreshPolicy.preferredActiveTrip(in: library.trips, at: date)
    guard let trip else { return .calm }
    let isConfirmed = TripFreshness(
      lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
      lastRefreshFailed: library.lastRefreshFailed(for: trip.id)
    ).isConfirmed
    return JourneyMood(status: TripPresentationStatus(trip: trip, referenceDate: date).kind, isConfirmed: isConfirmed)
  }

  /// Regular width draws "My Trips" at the top of the column, aligned with the tickets; the bar
  /// keeps only its buttons. The sidebar counts too, though a sidebar column reports compact.
  private var usesColumnTitle: Bool {
    isSidebar || (horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom != .phone)
  }

  private var emptyState: some View {
    TripsEmptyState(
      showsWordmark: travelLog.entries.isEmpty,
      addJourney: { intake.presentAddJourney() },
      search: { navigation.open(.stations) }
    )
  }

  @ViewBuilder
  private var notices: some View {
    // The compact header and the ticket's own freshness line cover this on a phone.
    if !usesCompactHeader { liveDataFreshness }
    providerStatus
    ticketStorageStatus
    if library.tripArchiveRecoveryRequired {
      TrainTrackerNotice(
        "Saved trains need attention",
        message: "Roundhouse couldn't read your saved-train archive. The original data is preserved and changes are paused."
      ) {
        Button("Open Recovery in Settings") { navigation.open(TripsRoute.settings) }
      }
    }
    if library.pushDeliveryWarning {
      pushDeliveryWarning
    }
    if let rejection = PushTripRejectionPresentation(rejections: Array(library.pushAlertRejections.values)) {
      TrainTrackerNotice(rejection.title, message: rejection.message, systemImage: "bell.slash.fill", tone: .informational) {
        EmptyView()
      }
    }
  }

  @ViewBuilder
  private var ticketStorageStatus: some View {
    if let loadError = ticketVault.loadError {
      TrainTrackerNotice("Saved tickets need attention", message: loadError, systemImage: "externaldrive.badge.exclamationmark") {
        Button("Try Again") { ticketVault.reload() }
      }
    }
  }

  @ViewBuilder
  private var unfinishedImports: some View {
    let tickets = ticketVault.draftTickets
    let reviews = ticketVault.reviews
    if !tickets.isEmpty || !reviews.isEmpty {
      tripSection(title: JourneySearchCopy.Plan.toReview) {
        VStack(spacing: 0) {
          ForEach(tickets) { ticket in
            HStack(spacing: TrainTrackerSpacing.space8) {
              Button { intake.review(ticket: ticket) } label: {
                UnfinishedImportRow(
                  title: reviewTitle(origin: ticket.suggestion.originGuess, destination: ticket.suggestion.destinationGuess),
                  subtitle: reviewSubtitle(origin: ticket.suggestion.originGuess, destination: ticket.suggestion.destinationGuess,
                                           original: ticket.title, source: ticket.kindTitle),
                  date: ticket.updatedAt, actionLabel: JourneySearchCopy.Plan.continueReview
                )
                  .padding(.vertical, TrainTrackerSpacing.space12)
              }
              .buttonStyle(.plain)
              .accessibilityHint("Continues reviewing this ticket")
              .accessibilityIdentifier("resumeImport")
              .contextMenu { keepWithoutJourneyButton(ticket) }
              reviewActionsMenu { keepWithoutJourneyButton(ticket) }
            }
            if ticket.id != tickets.last?.id || !reviews.isEmpty {
              Divider().overlay(Color.ttBorderSubtle)
            }
          }
          ForEach(reviews) { review in
            HStack(spacing: TrainTrackerSpacing.space8) {
              Button { intake.review(suggestion: review) } label: {
                UnfinishedImportRow(
                  title: reviewTitle(origin: review.originGuess, destination: review.destinationGuess),
                  subtitle: reviewSubtitle(origin: review.originGuess, destination: review.destinationGuess,
                                           original: review.subtitle, source: review.sourceDescription),
                  date: nil, actionLabel: JourneySearchCopy.Plan.continueReview
                )
                .padding(.vertical, TrainTrackerSpacing.space12)
              }
              .buttonStyle(.plain)
              .accessibilityHint("Continues this review")
              .contextMenu { discardReviewButton(review.id) }
              reviewActionsMenu { discardReviewButton(review.id) }
            }
            if review.id != reviews.last?.id {
              Divider().overlay(Color.ttBorderSubtle)
            }
          }
        }
        .padding(.horizontal, LayoutMetrics.cardInset)
        .trainTrackerSurface()
      }
    }
  }

  private func keepWithoutJourneyButton(_ ticket: LocalJourneyTicket) -> some View {
    Button(ticket.isLinked && ticket.suggestion.routeReviewReason == .multipleJourneys
           ? String(localized: "Finish Reviewing Ticket") : JourneySearchCopy.Plan.keepWithoutJourney) {
      do { try ticketVault.keepWithoutJourney(id: ticket.id) } catch { intake.report(error.localizedDescription) }
    }
  }

  private func discardReviewButton(_ id: UUID) -> some View {
    Button(JourneySearchCopy.Plan.discardReview, role: .destructive) {
      do { try ticketVault.discardReview(id: id) } catch { intake.report(error.localizedDescription) }
    }
  }

  /// A visible way to the row's secondary actions, which were otherwise long-press only.
  private func reviewActionsMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
    Menu(content: items) {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
        .foregroundStyle(Color.ttTextSecondary)
        .frame(width: 44, height: 44)
        .contentShape(.rect)
    }
    .accessibilityLabel(JourneySearchCopy.Plan.reviewActions)
  }

  /// A partial extraction is useful context, but must not look like a complete route.
  private func reviewTitle(origin: String?, destination: String?) -> String {
    switch (nonblankReviewText(origin), nonblankReviewText(destination)) {
    case let (origin?, destination?): return "\(origin) → \(destination)"
    case let (origin?, nil): return "From \(origin)"
    case let (nil, destination?): return "To \(destination)"
    case (nil, nil): return "Journey to Review"
    }
  }

  private func reviewSubtitle(origin: String?, destination: String?, original: String?, source: String) -> String {
    // Keep an unparsed filename or email subject available without making it the action title.
    guard nonblankReviewText(origin) == nil, nonblankReviewText(destination) == nil,
          let original = nonblankReviewText(original), original != source else { return source }
    return "\(original) · \(source)"
  }

  private func nonblankReviewText(_ text: String?) -> String? {
    guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  private var journeyPreviewPlan: TrackedJourneyPlan? {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-JourneyPlanPreviewOneWay") {
        return planLibrary.plans.first { $0.returnDirection == nil }
      }
    #endif
    return planLibrary.plans.first { $0.returnDirection != nil }
  }

  private var pushDeliveryWarning: some View {
    let presentation = PushDeliveryWarningPresentation(
      reason: library.pushDeliveryWarningReason,
      deviceName: TrainTrackerDeviceName.current,
      context: library.pushDeliveryWarningContext
    )
    return TrainTrackerNotice(presentation.title, message: presentation.message, systemImage: presentation.systemImage, tone: .informational) {
      Button(presentation.actionTitle) {
        handlePushWarningAction(presentation.action)
      }
      .accessibilityHint(presentation.accessibilityHint)
    }
  }

  /// One fixed line while trains are live: polling rewrites its text in place instead of
  /// inserting and removing a row, so the list never jumps.
  @ViewBuilder
  private var liveDataFreshness: some View {
    if library.hasRefreshableTrips, library.refreshError == nil {
      Label {
        Text(MyTripsFreshnessPresentation.text(lastUpdated: library.lastUpdated, isRefreshing: library.isRefreshing))
          .monospacedDigit()
      } icon: {
        Image(systemName: "dot.radiowaves.left.and.right")
      }
      .font(.footnote)
      .foregroundStyle(Color.ttTextSecondary)
      .accessibilityIdentifier("liveDataFreshness")
    }
  }

  @ViewBuilder
  private var providerStatus: some View {
    if library.hasRefreshableTrips, connectivity.isOffline {
      // No signal (a tunnel, a flight) is expected, not a fault: say so, keep the saved times,
      // and check again by itself when a connection returns.
      TrainTrackerNotice(
        "You’re offline",
        message: "Showing times from the last check. Roundhouse checks again when you’re back online.",
        systemImage: "wifi.slash",
        tone: .informational
      )
    } else if library.hasRefreshableTrips, library.refreshError != nil {
      TrainTrackerNotice(
        "Live updates paused",
        message: "Your saved trips are still here. Check your connection, then try again.",
        systemImage: "wifi.exclamationmark"
      ) {
        Button("Try Again") {
          Task { await library.refreshTrackedTrips() }
        }
        .accessibilityHint("Requests the latest live data for tracked trips")
      }
    }
  }

  private func handlePushWarningAction(_ action: PushDeliveryWarningPresentation.Action) {
    switch action {
    case .openNotificationSettings:
      guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
      openURL(url)
    case .retry:
      library.retryPushDelivery()
    }
  }

  @ViewBuilder
  private func tripSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.ttTextPrimary)
        .accessibilityAddTraits(.isHeader)
      content()
    }
  }
}

enum MyTripsFreshnessPresentation {
  /// "Checking live rail data" only while a check is running; before the first check
  /// completes it says so, matching the ticket's "Not checked yet".
  static func text(
    lastUpdated: Date?,
    isRefreshing: Bool = false,
    timeZone: TimeZone = .autoupdatingCurrent,
    locale: Locale = .trainTrackerTime
  ) -> String {
    guard let lastUpdated else {
      return isRefreshing ? JourneySearchCopy.Plan.checkingLiveData : JourneySearchCopy.Plan.notCheckedYet
    }
    let time = lastUpdated.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    return JourneySearchCopy.Plan.liveDataUpdated(at: time)
  }
}

private extension View {
  /// Pins a custom bar above the scroll content. From iOS 26 the system gives it the same
  /// scroll-edge treatment as a navigation bar; earlier systems get the bar material.
  @ViewBuilder
  func myTripsTopBar<Bar: View>(isEnabled: Bool, isPanel: Bool = false, @ViewBuilder bar: () -> Bar) -> some View {
    if !isEnabled {
      self
    } else if isPanel {
      // The bar draws its own rounded panel over the map, so it takes no system bar treatment.
      safeAreaInset(edge: .top, spacing: 0) { bar() }
    } else if #available(iOS 26.0, *) {
      safeAreaBar(edge: .top, spacing: 0) { bar() }
    } else {
      safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
    }
  }

}

/// A signed trip link to hand to the system share sheet.
struct TripShareItem: Identifiable {
  let id = UUID()
  let url: URL
  let subject: String
}

private struct TripShareSheet: UIViewControllerRepresentable {
  let item: TripShareItem

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: ["Add this train to Roundhouse. Ticket and passenger details are not shared.", item.url],
      applicationActivities: nil
    )
    controller.setValue(item.subject, forKey: "subject")
    return controller
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
