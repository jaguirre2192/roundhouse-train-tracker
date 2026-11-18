import SwiftUI
import TrainTrackerCore

/// A train as its map with the journey resting over it. My Trips uses it for the train in focus
/// and the trip screen uses it for any other, so the two read as one place.
struct MapBackedJourneyView<Notices: View, Actions: View, Extra: View>: View {
    @Environment(TripLibrary.self) private var library
    @Environment(JourneyPlanLibrary.self) private var planLibrary: JourneyPlanLibrary?
    @Environment(LocalJourneyTicketStore.self) private var ticketVault
    @Environment(\.journeyReferenceDate) private var referenceDate

    let trip: TrainTrip
    var routeTimeZones: JourneyPlanRouteTimeZones? = nil
    var selectedSegment: JourneyPlanSegment? = nil
    @Binding var detent: JourneyDrawerDetent
    /// Anything the rider should know before reading on: offline, paused alerts.
    @ViewBuilder var notices: () -> Notices
    /// Share, stop tracking and the like, under the journey.
    @ViewBuilder var actions: () -> Actions
    /// Whatever follows this journey at full height: on My Trips, the other trips.
    @ViewBuilder var extra: () -> Extra

    /// The screen's height inside its safe area and the bottom inset below it, measured from a
    /// clear layer so the map itself is free to run past every edge.
    @State private var space = JourneyPanelGeometry()
    /// Ticks every half minute so countdowns and the trust word stay current.
    @State private var clock = Date.now
    @State private var ticketExpanded = false
    @State private var sideContentHeight: CGFloat?
    /// Ties the stop list and the ticket's line to the map's camera.
    @State private var mapLink = JourneyMapLink()

    /// On a wide screen (iPad, an unfolded iPhone Duo) the journey floats beside the map in a
    /// panel of its own; on a narrow one it rests over the map's lower part and can be raised.
    /// The choice follows the room this view actually has, not the device.
    private var floatsBeside: Bool {
        space.floatsBeside
    }
    /// About half the width on a small screen, and never wider than a phone's column.
    private var sidePanelWidth: CGFloat { space.panelWidth }
    private static var sidePanelMargin: CGFloat { TrainTrackerSpacing.space16 }

    var body: some View {
        let date = referenceDate ?? clock
        let model = model(at: date)
        let metrics = JourneyDrawerMetrics(contentHeight: space.height, bottomInset: space.bottom)
        // A clear layer the size of the safe area: the map is its backdrop and runs past every
        // edge; the panel rests on it. Neither changes its size, so the measurement holds.
        Color.clear
            .onGeometryChange(for: JourneyPanelGeometry.self) { proxy in
                JourneyPanelGeometry(proxy)
            } action: {
                space = $0
                mapLink.scrubsDirectly = floatsBeside
            }
            .background {
                TripRouteMapView(
                    trip: trip, chrome: .compact,
                    isRefreshing: library.isRefreshing,
                    refreshTrip: referenceDate == nil ? { Task { await library.refreshTrackedTrip(id: trip.id) } } : nil,
                    bottomInset: floatsBeside ? 0 : max(metrics.peek - space.bottom, 0),
                    fillsScreen: true,
                    obscuredBottom: floatsBeside ? 0 : max(metrics.mapInset(for: detent) - metrics.peek, 0),
                    leadingInset: space.mapLeadingInset,
                    trust: model.trust, freshness: model.freshness,
                    focus: Bindable(mapLink).focus,
                    focusCaption: focusCaption(in: model)
                )
            }
            .overlay(alignment: floatsBeside ? .topLeading : .bottom) {
                if space.height > 0, floatsBeside {
                    sidePanel(model, at: date)
                } else if space.height > 0 {
                    JourneyDrawer(detent: $detent, metrics: metrics, mood: model.mood) {
                        JourneyPeekStrip(card: model.card, timeZoneIdentifier: { model.zones.timeZoneIdentifier(for: $0) })
                    } content: {
                        journey(model, at: date)
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .environment(mapLink)
                }
            }
            .onChange(of: trip.id) { mapLink.focus = nil }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                clock = .now
            }
        }
    }

    fileprivate struct Model {
        let card: ActiveTripCardPresentation
        let experience: JourneyExperiencePresentation
        let zones: TripDetailTimeZoneContext
        let segment: JourneyPlanSegment?
        let trust: JourneyTrust
        let freshness: TripFreshness
        let mood: JourneyMood
    }

    private func model(at date: Date) -> Model {
        let plans = planLibrary?.plans ?? []
        let segment = selectedSegment ?? JourneyTripContext.selectedSegment(for: trip.id, plans: plans)
        let zones = TripDetailTimeZoneContext(
            trip: trip, routeTimeZones: routeTimeZones, plans: plans,
            additionalPlaces: segment.map { [$0.from, $0.to] } ?? []
        )
        let checked = library.lastSuccessfulCheck(for: trip.id)
        let failed = library.lastRefreshFailed(for: trip.id)
        let card = ActiveTripCardPresentation(
            trip: trip, routeTimeZones: routeTimeZones ?? zones.routeTimeZones, referenceDate: date,
            lastSuccessfulCheck: checked, lastRefreshFailed: failed, selectedSegment: segment
        )
        let experience = JourneyExperiencePresentation(
            trip: trip, timeZones: zones, referenceDate: date,
            lastSuccessfulCheck: checked, refreshFailed: failed, selectedSegment: segment
        )
        let freshness = TripFreshness(lastSuccessfulCheck: checked, lastRefreshFailed: failed)
        return Model(
            card: card, experience: experience, zones: zones, segment: segment,
            trust: JourneyTrust(card: card), freshness: freshness,
            mood: JourneyMood(status: card.status.kind, isConfirmed: freshness.isConfirmed)
        )
    }

    /// The journey as a panel floating beside the map: the same ticket, stops and actions, in
    /// one scrolling column as tall as the screen allows.
    private func sidePanel(_ model: Model, at date: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return ScrollView {
            journey(model, at: date)
                .padding(.top, TrainTrackerSpacing.space16)
                .padding(.bottom, TrainTrackerSpacing.space24)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            sideContentHeight = height
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("journeySidePanel")
        .frame(width: sidePanelWidth, height: min(sideContentHeight ?? space.maximumPanelHeight, space.maximumPanelHeight))
        .background { JourneyPanelSurface() }
        .clipShape(shape)
        .shadow(color: Color.ttBackgroundBrand.opacity(0.16), radius: 18, y: 6)
        .padding(Self.sidePanelMargin)
        .environment(mapLink)
    }

    private func journey(_ model: Model, at date: Date) -> some View {
        let seat = ticketVault.tickets(forTrip: trip.id.rawValue).first { $0.details.coach != nil && $0.details.seat != nil }
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                WatchingTrainControl(trip: trip, selectedSegment: model.segment,
                                     hasEnded: model.card.effectiveProgress.phase == .ended, inSidePanel: floatsBeside)
                JourneyTrackingHeader(experience: model.experience)

                DisclosureGroup(isExpanded: $ticketExpanded) {
                    ticket(model, seat: seat, at: date)
                        .accessibilityIdentifier("journeyExpandedTicket")
                        .padding(.top, TrainTrackerSpacing.space8)
                } label: {
                    if ticketExpanded {
                        Text(LiveLineTicketPresentation.serviceName(for: trip))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ttTextPrimary)
                    } else {
                        LiveLineTicket(
                            trip: trip, density: .routeSummary,
                            routeTimeZones: model.card.routeTimeZones,
                            timeZoneIdentifier: { model.zones.timeZoneIdentifier(for: $0) },
                            lastSuccessfulCheck: model.card.lastSuccessfulCheck,
                            lastRefreshFailed: model.card.lastRefreshFailed,
                            selectedSegment: model.segment, referenceDate: date,
                            showsFacts: false
                        )
                    }
                }
                .disclosureGroupStyle(JourneyTicketDisclosureStyle(identifier: "journeyTicket-\(trip.id.rawValue)"))
                .tint(Color.ttActionTint)

                TripUpdatesRow(experience: model.experience)
                ForEach(model.experience.currentAlerts) { alert in
                    DisruptionBanner(alert: alert)
                }
                if model.card.effectiveProgress.phase == .ended, !trip.isCancelled, !library.isWatchingOnly(trip.id) {
                    // The stamped ticket's stub, torn off and kept; the log is one tap away.
                    if let stub = TravelLog.shared.entry(id: trip.id.rawValue)
                        ?? TravelLog.finishedRide(trip, in: library, plans: planLibrary?.plans ?? [], at: date) {
                        ArrivalKeepsake(entry: stub)
                    } else {
                        TravelLogLink()
                    }
                }
                notices()
            }

            if floatsBeside {
                Button {
                    withAnimation { detent = detent == .full ? .half : .full }
                } label: {
                    HStack {
                        Text(detent == .full ? "Fewer details" : "Stops and details")
                        Spacer()
                        Image(systemName: detent == .full ? "chevron.up" : "chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .accessibilityIdentifier("journeyExpandDetails")
                .accessibilityValue(detent == .full ? "Expanded" : "Collapsed")
            }
            if !floatsBeside || detent == .full {
                journeyDetails(model, at: date)
            }
        }
        .frame(maxWidth: LayoutMetrics.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, LayoutMetrics.pageInset)
        .padding(.top, TrainTrackerSpacing.space4)
        .frame(maxWidth: .infinity)
    }

    private func ticket(_ model: Model, seat: LocalJourneyTicket?, at date: Date) -> some View {
        LiveLineTicket(
            trip: trip, routeTimeZones: model.card.routeTimeZones,
            timeZoneIdentifier: { model.zones.timeZoneIdentifier(for: $0) },
            lastSuccessfulCheck: model.card.lastSuccessfulCheck,
            lastRefreshFailed: model.card.lastRefreshFailed,
            selectedSegment: model.segment, coach: seat?.details.coach, seat: seat?.details.seat,
            referenceDate: date, showsFacts: false, linksToMap: true
        )
        .printsTicket(id: trip.id.rawValue)
    }

    private func journeyDetails(_ model: Model, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space24) {
            WindowSeatLink(trip: trip, selectedStops: model.card.passengerProgress?.stops)
            JourneyRouteTimeline(presentation: model.experience, selectedStopID: mapLink.focus?.stopID) { stop in
                // The panel steps down so the map, and the stop on it, can be seen.
                mapLink.focus = .stop(stop.id)
                if !floatsBeside {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { detent = .half }
                }
            }

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                if referenceDate == nil {
                    if !library.isWatchingOnly(trip.id), let alighting = wakeStop(in: model) {
                        StopWakeAlertControl(trip: trip, stop: alighting)
                    }
                    JourneyLiveActivityControls(trip: trip, selectedSegment: model.segment)
                }
                JourneyTicketsSection(owner: .trip(trip.id.rawValue))
                MeetTrainAction(trip: trip, selectedSegment: model.segment)

                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    if AmtrakerAttributionLink.applies(to: trip) {
                        AmtrakerAttributionLink()
                    }
                    actions()
                }
            }
            extra()
        }
    }

}

/// Frosted over the map; a plain surface when transparency is reduced or contrast increased.
extension MapBackedJourneyView {
    /// The focused stop's name and time, for its mark on the map.
    fileprivate func focusCaption(in model: Model) -> String? {
        guard let id = mapLink.focus?.stopID,
              let stop = trip.stopTimes.first(where: { $0.id == id }) else { return nil }
        let isLast = stop.id == model.card.effectiveProgress.stops.last?.id
        let time = StopTimelineTimePresentation(
            stop: stop, event: isLast ? .arrival : .departure,
            timeZoneIdentifier: model.zones.timeZoneIdentifier(for: stop)
        ).timeText
        return [stop.station.displayName, time].compactMap { $0 }.joined(separator: " · ")
    }

    /// The stop the rider gets off at, while it is still ahead of a running or upcoming train.
    fileprivate func wakeStop(in model: Model) -> StopTime? {
        let progress = model.card.effectiveProgress
        // A timetable that has run out does not mean the stop was reached: a late train still
        // has it ahead, and the alert is still worth offering. Only a reported arrival ends it.
        guard progress.phase != .unavailable, !trip.isCancelled, !progress.isCancelled,
              !progress.evidence.isArrivalConfirmed,
              let last = progress.stops.last, !ArrivalEvidence.hasReached(last, progress: progress),
              progress.stops.count > 1 else { return nil }
        return last
    }
}

/// The journey in one line, shown while the map has the screen: where the train is headed next,
/// how far off that is, the track, and how it is running.
struct JourneyPeekStrip: View {
    let card: ActiveTripCardPresentation
    var timeZoneIdentifier: (StopTime) -> String? = { _ in nil }

    var body: some View {
        // Everything while it fits; at large text sizes the strip gives up the track, then the
        // countdown, and keeps where the train is headed and how it is running.
        ViewThatFits(in: .horizontal) {
            row(showsAway: true, showsPlatform: true)
            row(showsAway: true, showsPlatform: false)
            row(showsAway: false, showsPlatform: false)
            nextStop
        }
        .padding(.horizontal, LayoutMetrics.pageInset)
        .padding(.top, TrainTrackerSpacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var nextStop: some View {
        cell(card.nextStopLabel, value: card.guidanceStop?.station.displayName ?? card.nextStopValue)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(showsAway: Bool, showsPlatform: Bool) -> some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space16) {
            nextStop
                .frame(minWidth: 96, alignment: .leading)
            if showsAway, let away = Self.timeAway(for: card) {
                cell(card.isBeforeBoarding ? "Leaves in" : "In", value: away).fixedSize()
            }
            if showsPlatform, card.platformValue != "Not in feed" {
                cell(card.platformLabel, value: card.platformValue, color: card.platformValueColor).fixedSize()
            }
            cell(card.detailStatusLabel, value: card.detailStatusValue, color: statusColor).fixedSize()
        }
    }

    private func cell(_ label: String, value: String, color: Color = .ttTextPrimary) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
            FlapText(value, font: .headline, color: color)
        }
        .lineLimit(1)
    }

    /// Saved times never take an alarm color, as on the ticket's badge.
    private var statusColor: Color {
        let isConfirmed = TripFreshness(
            lastSuccessfulCheck: card.lastSuccessfulCheck, lastRefreshFailed: card.lastRefreshFailed
        ).isConfirmed
        return card.status.kind.isDisruption && isConfirmed ? card.status.color : .ttTextPrimary
    }

    /// "12 min", "1 h 05", or nil once there is no stop ahead or no time for it.
    static func timeAway(for card: ActiveTripCardPresentation) -> String? {
        guard card.effectiveProgress.phase != .ended, !card.trip.isCancelled, let stop = card.guidanceStop else { return nil }
        let date = card.isBeforeBoarding
            ? stop.expectedDeparture ?? stop.scheduledDeparture
            : stop.expectedArrival ?? stop.scheduledArrival ?? stop.expectedDeparture ?? stop.scheduledDeparture
        guard let date else { return nil }
        return timeAway(until: date, from: card.referenceDate)
    }

    static func timeAway(until date: Date, from reference: Date) -> String {
        let minutes = Int((date.timeIntervalSince(reference) / 60).rounded(.up))
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" }
        return "\(minutes / (24 * 60)) d"
    }
}
