import SwiftUI
import TrainTrackerCore

/// The first thing on My Trips: the next relevant stage of the most relevant saved journey.
/// Stages follow the timetable and provider updates; the passenger's location is never assumed.
/// My Trips owns the clock and passes the selected focus, so its lists can omit what this shows.
struct JourneyHomeFocusView: View {
    @Environment(JourneyPlanLibrary.self) private var plans
    @Environment(TripLibrary.self) private var trips
    @Environment(LocalJourneyTicketStore.self) private var tickets

    let focus: JourneyHomeGuidance
    let referenceDate: Date
    var trainAlreadyVisible = false

    var body: some View {
        let planTickets = tickets.tickets(forPlan: focus.plan.id)
        VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
            if showsSavedCard {
                statusLine
                TripsRouteLink(route: .journey(focus.plan.id)) {
                    TicketStubCard(content: TicketStubCardContent(
                        journey: JourneyPlanPresentation(plan: focus.plan, trips: trips.trips, at: referenceDate)
                    ))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens journey details")
            } else {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    // The ink ticket already names both ends in large codes, so the route title
                    // is dropped when the ticket will show.
                    if !showsLiveTicket {
                        Text("\(focus.origin.displayName) → \(focus.destination.displayName)")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.ttTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    statusLine
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if focus.isRecentCompletion {
                    Text(focus.completionText)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    JourneyPlanFocusView(plan: focus.plan, stage: focus.stage, referenceDate: referenceDate, context: .home, showsTrainTicket: !trainAlreadyVisible)
                    JourneyDisruptionGuidanceView(plan: focus.plan, stage: focus.stage, referenceDate: referenceDate)
                }
            }
            if !planTickets.isEmpty || !showsSavedCard {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: TrainTrackerSpacing.space12) { actionButtons(planTickets: planTickets) }
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) { actionButtons(planTickets: planTickets) }
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyHomeFocus")
    }

    /// Journeys saved before selected legs were recorded have no stage detail to show, so the
    /// saved journey card stands in rather than an empty focus.
    private var showsSavedCard: Bool {
        !focus.isRecentCompletion && focus.stage.kind == .legacy && focus.stage.focusTrip == nil
    }

    private var showsLiveTicket: Bool {
        !focus.isRecentCompletion && focus.stage.kind != .connection
            && focus.stage.focusTrip != nil && focus.stage.focusSegment != nil
    }

    private var statusLine: some View {
        Text(focus.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttTextOperational)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actionButtons(planTickets: [LocalJourneyTicket]) -> some View {
        if let ticket = planTickets.first {
            NavigationLink {
                if planTickets.count == 1 {
                    LocalTicketDetailView(ticketID: ticket.id)
                } else {
                    JourneyPlanDetailView(plan: focus.plan, planLibrary: plans)
                        .id(focus.plan.id)
                }
            } label: {
                Label(planTickets.count == 1 ? "Show Ticket" : "Show Tickets", systemImage: "qrcode")
            }
            .trainTrackerPrimaryAction()
            .accessibilityIdentifier("homeShowTicket")
        }
        if !showsSavedCard {
            TripsRouteLink(route: .journey(focus.plan.id), marksSelection: false) {
                Label("Open Journey", systemImage: "arrow.right")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("homeOpenJourney")
        }
    }
}

/// Can also be embedded beneath the focused train on the journey detail screen.
struct JourneyDisruptionGuidanceView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(AppNavigationModel.self) private var navigation
    let plan: TrackedJourneyPlan
    let stage: JourneyPlanStage
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
            if let presentation, let arrival = JourneyHomeGuidance.arrivalText(presentation) {
                Text(arrival)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            if recovery == nil, let connection = stage.connection, let text = JourneyHomeGuidance.connectionText(connection) {
                Text(text).font(.subheadline)
            }
            if let place = directionsPlace, let url = JourneyHomeGuidance.directionsURL(to: place) {
                Link(destination: url) {
                    Label("Directions to \(place.displayName)", systemImage: "figure.walk")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens walking directions in Maps")
            }
            if recovery == nil, shouldOfferAlternatives, let request = JourneyHomeGuidance.alternatives(stage: stage, at: referenceDate) {
                Text("Search other trains from \(request.originName) to \(request.destinationName). Check your ticket’s validity with the operator before changing trains.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                Button {
                    navigation.openTicketJourneySearch(request)
                } label: {
                    Label("Find alternative trains", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
            }
            if let presentation, presentation.needsRefresh {
                Button("Refresh train details") {
                    Task { await library.refreshTrackedTrip(id: presentation.trip.id) }
                }
                .buttonStyle(.bordered)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presentation: JourneyExperiencePresentation? {
        guard let trip = stage.focusTrip, let segment = stage.focusSegment else { return nil }
        return JourneyExperiencePresentation(trip: trip,
            timeZones: TripDetailTimeZoneContext(trip: trip, plans: [plan], additionalPlaces: [segment.from, segment.to]),
            referenceDate: referenceDate, lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
            refreshFailed: library.lastRefreshFailed(for: trip.id), selectedSegment: segment)
    }

    private var recovery: JourneyRecoveryRequest? {
        JourneyRecoveryRequest.make(stage: stage, trips: library.trips, at: referenceDate)
    }

    private var shouldOfferAlternatives: Bool {
        presentation?.isDisrupted == true || stage.connection != nil || stage.kind == .untracked
    }

    private var directionsPlace: RailPlace? {
        if let connection = stage.connection { return connection.next.from }
        if stage.kind == .walk { return stage.focusSegment?.to }
        guard let presentation,
              presentation.progress.phase == .upcoming || presentation.progress.phase == .departureSoon else { return nil }
        return stage.focusSegment?.from
    }
}
