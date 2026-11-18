import SwiftUI
import TrainTrackerCore

struct JourneyPlanDetailView: View {
    @Environment(TripLibrary.self) private var tripLibrary
    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.journeyReferenceDate) private var referenceDate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(JourneyIntakeModel.self) private var intake
    @State private var removalController: JourneyPlanRemovalController
    @State private var removalRequest: JourneyPlanRemovalRequest?
    @State private var manageExpanded = false

    let plan: TrackedJourneyPlan

    init(plan: TrackedJourneyPlan, planLibrary: JourneyPlanLibrary) {
        self.plan = plan
        _removalController = State(initialValue: JourneyPlanRemovalController(
            planID: plan.id,
            library: planLibrary
        ))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            journeyContent(at: referenceDate ?? timeline.date)
        }
        .trainTrackerPageBackground()
        .navigationTitle("Journey")
        .navigationBarTitleDisplayMode(.inline)
        // On regular width the ticket names the journey; a centred "Journey" over it adds nothing.
        .trainTrackerBarTitleHidden(horizontalSizeClass == .regular)
        .trainTrackerShowSidebarButton()
        .sheet(item: $removalRequest) { _ in
            JourneyPlanRemovalView(
                controller: removalController,
                trips: tripLibrary.trips
            )
        }
        .onChange(of: planLibrary.plans) { _, plans in
            if !plans.contains(where: { $0.id == plan.id }) {
                dismiss()
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-JourneyPlanPreviewRemoval") {
                removalRequest = JourneyPlanRemovalRequest(planID: plan.id)
            }
            #endif
            guard referenceDate == nil else { return }
            await tripLibrary.refreshTrackedTrips()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                if scenePhase == .active { await tripLibrary.refreshTrackedTrips() }
            }
        }
    }

    private var currentPlan: TrackedJourneyPlan {
        planLibrary.plans.first { $0.id == plan.id } ?? plan
    }

    private func journeyContent(at date: Date) -> some View {
        let plan = currentPlan
        let presentation = JourneyPlanPresentation(plan: plan, trips: tripLibrary.trips, at: date)
        let stage = JourneyPlanStage(plan: plan, trips: tripLibrary.trips, referenceDate: date)
        let isReturn = stage.directionTitle == JourneySearchCopy.returnDirection
        let origin = isReturn ? plan.destination : plan.origin
        let destination = isReturn ? plan.origin : plan.destination
        let directions = [plan.outbound] + (plan.returnDirection.map { [$0] } ?? [])
        let mapTrip = self.mapTrip(for: stage)
        let mapSegment = mapTrip?.id == stage.focusTrip?.id ? stage.focusSegment : nil

        return JourneyPlanMapLayout(
            trip: mapTrip, selectedSegment: mapSegment, referenceDate: date,
            lastSuccessfulCheck: mapTrip.flatMap { tripLibrary.lastSuccessfulCheck(for: $0.id) },
            lastRefreshFailed: mapTrip.map { tripLibrary.lastRefreshFailed(for: $0.id) } ?? false,
            isRefreshing: tripLibrary.isRefreshing,
            refreshTrip: mapRefresh(for: mapTrip)
        ) { usesMapPanel in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                    if usesMapPanel, let mapTrip {
                        let service = LiveLineTicketPresentation.serviceName(for: mapTrip)
                        Text(service.isEmpty ? "Showing this train’s route" : "Showing \(service) route")
                            .font(.footnote)
                            .foregroundStyle(Color.ttTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("journeyPlanMapCaption")
                    }
                    // One ink ticket heads the screen: the train in focus when there is one (inside
                    // the focus view below), otherwise the journey itself.
                    if showsFocusTicket(stage) {
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                            Text("\(origin.displayName) → \(destination.displayName)")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Color.ttTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text("\(stage.directionTitle) · \(JourneyExperienceClock.date(stage.direction.departure, zone: origin.timeZoneIdentifier))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ttTextOperational)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    } else {
                        JourneyPlanTicket(plan: plan, presentation: presentation)
                    }

                    if let transfer = JourneyPlanUpcomingTransferPresentation(
                        stage: stage, trips: tripLibrary.trips, referenceDate: date
                    ) {
                        JourneyPlanUpcomingTransferView(transfer: transfer)
                    }

                    // Journeys saved before selected legs were recorded have no stage to focus on;
                    // skip the empty region so the itinerary follows the header directly.
                    if stage.kind != .legacy || stage.focusTrip != nil || stage.connection != nil {
                        JourneyPlanFocusView(plan: plan, stage: stage, referenceDate: date)
                        JourneyDisruptionGuidanceView(plan: plan, stage: stage, referenceDate: date)
                    }

                    ForEach(Array(presentation.directions.enumerated()), id: \.element.id) { index, direction in
                        if let segments = directions[index].selectedSegments {
                            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                                Text(directions.count == 1 ? "Trains and transfers" : direction.title)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Color.ttTextPrimary)
                                JourneyTransferDiagram(segments: segments)
                                JourneyPlanSelectedItinerary(segments: segments, referenceDate: date)
                            }
                        } else {
                            directionSection(
                                direction, showsRoute: directions.count > 1,
                                showsTimes: showsFocusTicket(stage), at: date
                            )
                        }
                    }

                    JourneyTicketsSection(owner: .plan(plan.id))

                    if usesMapPanel {
                        DisclosureGroup(isExpanded: $manageExpanded) {
                            removalActions(showsHeading: false)
                                .padding(.top, TrainTrackerSpacing.space12)
                        } label: {
                            Text("Manage Journey")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ttTextPrimary)
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("journeyPlanManageDisclosure")
                    } else {
                        removalActions()
                    }
                }
                .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
                .padding(LayoutMetrics.pageInset)
                .padding(.bottom, TrainTrackerSpacing.space32)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                let ids = Set(directions.flatMap(\.childTripIDs))
                for id in ids { await tripLibrary.refreshTrackedTrip(id: id) }
            }
        }
    }

    /// A map names one available train, never an inferred whole-journey route.
    private func mapTrip(for stage: JourneyPlanStage) -> TrainTrip? {
        let candidate: TrainTrip?
        if let focused = stage.focusTrip {
            candidate = focused
        } else if let firstID = stage.direction.childTripIDs.first {
            let matches = tripLibrary.trips.filter { $0.id == firstID }
            candidate = matches.count == 1 ? matches.first : nil
        } else {
            candidate = nil
        }
        guard let candidate, candidate.stopTimes.count > 1,
              candidate.stopTimes.allSatisfy({ stop in
                  let location = stop.station.location
                  return location.latitude.isFinite && location.longitude.isFinite
                      && abs(location.latitude) <= 90 && abs(location.longitude) <= 180
                      && (location.latitude != 0 || location.longitude != 0)
              }) else { return nil }
        return candidate
    }

    private func mapRefresh(for trip: TrainTrip?) -> (() -> Void)? {
        guard let trip, referenceDate == nil else { return nil }
        return { Task { await tripLibrary.refreshTrackedTrip(id: trip.id) } }
    }

    /// `showsRoute` is false for a one-way journey, whose header already names the route.
    /// Whether the focus view is showing a single train's ticket, which then heads the screen.
    private func showsFocusTicket(_ stage: JourneyPlanStage) -> Bool {
        stage.kind != .connection && stage.focusTrip != nil && stage.focusSegment != nil
    }

    /// A direction: its name and day, then its trains as a rail on a frosted group.
    private func directionSection(
        _ direction: JourneyPlanDirectionPresentation, showsRoute: Bool, showsTimes: Bool, at date: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(direction.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.ttTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    Text(direction.departureDateText)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                if showsRoute {
                    Text(direction.routeTitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                // The journey ticket prints these when it heads the screen.
                if showsTimes {
                    Text(JourneySearchCopy.Plan.departs(
                        date: direction.departureDateText,
                        time: direction.departureTimeText
                    ))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ttTextPrimary)
                    Text(JourneySearchCopy.Plan.arrives(
                        date: direction.arrivalDateText,
                        time: direction.arrivalTimeText
                    ))
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            JourneyLegList(children: direction.children, routeTimeZones: direction.routeTimeZones, referenceDate: date)
        }
    }

    private func removalActions(showsHeading: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            if showsHeading {
                Text("Manage Journey")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ttTextPrimary)
            }
            Text(JourneySearchCopy.Plan.groupExplanation)
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)

            if let failure = removalController.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttStatusDelayed)
                    .accessibilityElement(children: .combine)
            }

            Button {
                if removalController.removeGrouping() {
                    if let removed = removalController.removedGroup { intake.offerUndo(restoring: removed) }
                    dismiss()
                }
            } label: {
                Text(JourneySearchCopy.Plan.removeGroup).trainTrackerFullWidthAction()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(JourneySearchCopy.Accessibility.removeJourneyGroup.label)
            .accessibilityHint(JourneySearchCopy.Accessibility.removeJourneyGroup.hint)

            Button(role: .destructive) {
                removalController.prepareDestructiveReview()
                removalRequest = JourneyPlanRemovalRequest(planID: plan.id)
            } label: {
                Text(JourneySearchCopy.Plan.stopTrackingJourneyTrains).trainTrackerFullWidthAction()
            }
            .buttonStyle(.bordered)
            // The app-wide live tint would otherwise paint the destructive action blue.
            .tint(Color.ttStatusCancelled)
            .accessibilityLabel(JourneySearchCopy.Accessibility.stopTrackingJourneyTrains.label)
            .accessibilityHint(JourneySearchCopy.Accessibility.stopTrackingJourneyTrains.hint)
        }
        // On the page itself: two quiet actions do not need a card of their own.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, TrainTrackerSpacing.space8)
    }
}

private struct JourneyPlanRemovalRequest: Identifiable {
    let planID: UUID
    var id: UUID { planID }
}
