import SwiftUI
import TrainTrackerCore

struct JourneyPlanFocusView: View {
    @Environment(TripLibrary.self) private var library
    @Environment(LocalJourneyTicketStore.self) private var ticketVault
    @Environment(\.journeyReferenceDate) private var previewReferenceDate
    enum Context {
        /// Journey detail: every control for the focused train.
        case detail
        /// My Trips: the next step only; train controls live one tap away in the journey.
        case home
    }

    let plan: TrackedJourneyPlan
    let stage: JourneyPlanStage
    let referenceDate: Date
    var context: Context = .detail
    var showsTrainTicket = true

    var body: some View {
        let recovery = JourneyRecoveryRequest.make(stage: stage, trips: library.trips, at: referenceDate)
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
            if let recovery {
                let risk = stage.connection.flatMap { connection in
                    (connection.isTight || connection.isMissed) && connection.next.id == recovery.original.id ? connection : nil
                }
                JourneyRecoveryTicket(planID: plan.id, request: recovery, connection: risk, referenceDate: referenceDate)
                    .id(recovery)
            }
            if stage.kind == .connection, let connection = stage.connection {
                if recovery == nil {
                    JourneyConnectionView(connection: connection, nextTrip: stage.focusTrip, referenceDate: referenceDate)
                    connectionCheckLabel(connection)
                }
            } else if let trip = stage.focusTrip, let segment = stage.focusSegment {
                if showsTrainTicket {
                    let presentation = presentation(trip: trip, segment: segment)
                    if context == .home {
                        liveTicket(trip: trip, segment: segment, presentation: presentation)
                    } else {
                        LiveTripTicketHero(presentation: presentation)
                    }
                    if AmtrakerAttributionLink.applies(to: trip) {
                        AmtrakerAttributionLink()
                    }
                    ForEach(presentation.currentAlerts) { alert in
                        DisruptionBanner(alert: alert)
                    }
                }
            } else if stage.kind != .legacy {
                unavailableStep
            }

            if recovery == nil, stage.kind != .connection, let connection = stage.connection {
                TrainTrackerNotice(
                    connection.isMissed ? "Connection may be missed" : "Tight connection",
                    message: JourneyHomeGuidance.connectionRiskMessage(connection)
                ) {
                    connectionCheckLabel(connection)
                    if let timetable = connection.timetable {
                        ConnectionTimetableView(timetable: timetable, showsAvailableInterval: connection.isMissed || connection.estimatedMinutes == nil)
                    }
                    if let id = connection.next.resolvedTripID, let nextTrip = library.trip(id: id) {
                        NavigationLink("View Connecting Train") {
                            TripDetailView(trip: nextTrip, selectedSegment: connection.next)
                        }
                    }
                }
            }

            if context == .detail, let trip = stage.focusTrip, let segment = stage.focusSegment {
                if previewReferenceDate == nil {
                    JourneyLiveActivityControls(trip: trip, selectedSegment: segment)
                }
                NavigationLink {
                    TripDetailView(trip: trip, selectedSegment: segment)
                } label: {
                    Label(stage.kind == .connection ? "View Next Train" : "Train Details and Stops", systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// On My Trips the focused train is the ink Line Ticket; its stub carries the freshness line.
    private func liveTicket(
        trip: TrainTrip, segment: JourneyPlanSegment, presentation: JourneyExperiencePresentation
    ) -> some View {
        let linked = (ticketVault.tickets(forPlan: plan.id) + ticketVault.tickets(forTrip: trip.id.rawValue))
            .first { $0.details.coach != nil && $0.details.seat != nil }
        return NavigationLink {
            TripDetailView(trip: trip, selectedSegment: segment)
        } label: {
            LiveLineTicket(
                trip: trip,
                routeTimeZones: presentation.timeZones.routeTimeZones,
                timeZoneIdentifier: { presentation.timeZones.timeZoneIdentifier(for: $0) },
                lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
                lastRefreshFailed: library.lastRefreshFailed(for: trip.id),
                selectedSegment: segment,
                coach: linked?.details.coach,
                seat: linked?.details.seat,
                referenceDate: referenceDate
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens live trip details")
    }

    private func connectionCheckLabel(_ connection: JourneyPlanStage.Connection) -> some View {
        let ids = [connection.previous.resolvedTripID, connection.next.resolvedTripID].compactMap { $0 }
        let failed = ids.contains { library.lastRefreshFailed(for: $0) }
        let checks = ids.compactMap { library.lastSuccessfulCheck(for: $0) }
        let text: String
        if failed {
            text = "Connection check failed · Saved times shown"
        } else if checks.count != 2 {
            text = "Connection not checked yet"
        } else if let oldest = checks.min() {
            let minutes = max(0, Int(referenceDate.timeIntervalSince(oldest) / 60))
            text = minutes == 0 ? "Both trains checked just now" : "Connection checked \(minutes) min ago"
        } else {
            text = "Connection details unavailable"
        }
        return Label(text, systemImage: failed ? "wifi.exclamationmark" : "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(failed ? Color.ttStatusDelayed : Color.ttTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var unavailableStep: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Label(stage.kind == .walk ? "Planned transfer" : "Tracking unavailable for this leg", systemImage: stage.kind == .walk ? "figure.walk" : "info.circle")
                .font(.headline)
                .foregroundStyle(Color.ttTextPrimary)
            if let segment = stage.focusSegment {
                Text("\(segment.from.displayName) → \(segment.to.displayName)")
                    .font(.title3.weight(.semibold))
                if let departure = segment.departure {
                    Text("Timetable departure \(JourneyExperienceClock.labeledTime(departure, zone: segment.from.timeZoneIdentifier))")
                        .font(.subheadline)
                }
                if let duration = segment.duration {
                    Text("Planned walk · \(max(1, Int(ceil(duration / 60)))) min")
                        .font(.subheadline)
                }
            }
            Text(stage.kind == .walk ? "Follow station signs and check the next train’s departure information." : "Your saved journey is here. Check the operator for the latest information on this leg.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .padding(LayoutMetrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trainTrackerSurface()
    }

    private func presentation(trip: TrainTrip, segment: JourneyPlanSegment) -> JourneyExperiencePresentation {
        JourneyExperiencePresentation(
            trip: trip,
            timeZones: TripDetailTimeZoneContext(trip: trip, plans: [plan], additionalPlaces: [segment.from, segment.to]),
            referenceDate: referenceDate,
            lastSuccessfulCheck: library.lastSuccessfulCheck(for: trip.id),
            refreshFailed: library.lastRefreshFailed(for: trip.id),
            selectedSegment: segment
        )
    }
}
