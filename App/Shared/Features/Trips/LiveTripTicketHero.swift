import SwiftUI
import TrainTrackerCore

/// The focused train's route facts, stub and actions on ink ticket stock.
struct LiveTripTicketHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(LocalJourneyTicketStore.self) private var ticketVault
    @Environment(TripLibrary.self) private var library: TripLibrary?
    @Environment(JourneyPlanLibrary.self) private var plans: JourneyPlanLibrary?
    @State private var opensPlatformBoard = false

    let presentation: JourneyExperiencePresentation
    /// False where a headline under the ticket states the status (the journey screen).
    var showsStatusBadge = true

    private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

    var body: some View {
        let linkedTicket = ticketVault.tickets(forTrip: presentation.trip.id.rawValue).first
        let boarding = PlatformBoardPresentation(experience: presentation,
                                                journal: library?.changeJournal(for: presentation.trip.id) ?? .init(),
                                                watching: library?.isWatchingOnly(presentation.trip.id) == true, plans: plans?.plans ?? [])

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                header
                codes
            }
            .padding(LayoutMetrics.cardInset)

            TicketPerforation.onInk

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                TicketStubGrid(
                    fields: stubFields(ticket: linkedTicket, boarding: boarding),
                    labelColor: secondaryOnInk,
                    valueColor: .ttTextOnBrand,
                    openPlatform: boarding == nil ? nil : { opensPlatformBoard = true }
                )
                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(secondaryOnInk)
                    .fixedSize(horizontal: false, vertical: true)
                actions(ticket: linkedTicket)
            }
            .padding(LayoutMetrics.cardInset)
        }
        .liveTicketStyle()
        .liveChangeFeedback(LiveChangeSignal(
            stop: presentation.progress.focusStop,
            status: TripPresentationStatus(trip: presentation.trip, referenceDate: presentation.referenceDate, progress: presentation.progress),
            isConfirmed: presentation.lastSuccessfulCheck != nil && !presentation.refreshFailed))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTripTicketHero")
        .navigationDestination(isPresented: $opensPlatformBoard) { PlatformBoardView(experience: presentation) }
    }

    /// The journey's mood, for controls that take a hint of it.
    private var mood: JourneyMood {
        JourneyMood(
            status: TripPresentationStatus(trip: presentation.trip, referenceDate: presentation.referenceDate, progress: presentation.progress).kind,
            isConfirmed: TripFreshness(lastSuccessfulCheck: presentation.lastSuccessfulCheck, lastRefreshFailed: presentation.refreshFailed).isConfirmed
        )
    }

    @ViewBuilder
    private var header: some View {
        if !showsStatusBadge {
            serviceHeader
        } else if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                serviceHeader
                statusBadge
            }
        } else {
            // The train's name is never truncated for the badge; the badge drops beneath it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    serviceHeader.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    statusBadge
                }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    serviceHeader
                    statusBadge
                }
            }
        }
    }

    private var statusBadge: some View {
        TicketStatusBadge(
            status: TripPresentationStatus(trip: presentation.trip, referenceDate: presentation.referenceDate, progress: presentation.progress),
            isConfirmed: TripFreshness(lastSuccessfulCheck: presentation.lastSuccessfulCheck, lastRefreshFailed: presentation.refreshFailed).isConfirmed
        )
    }

    private var serviceHeader: some View {
        Text(LiveLineTicketPresentation.serviceName(for: presentation.trip))
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(secondaryOnInk)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var codes: some View {
        let origin = presentation.progress.stops.first
        let destination = presentation.progress.stops.last
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TrainTrackerSpacing.space16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: TrainTrackerSpacing.space16))
        return layout {
            endpoint(stop: origin, fallback: presentation.originName, event: .departure, alignment: .leading)
            endpoint(stop: destination, fallback: presentation.destinationName, event: .arrival,
                     alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
    }

    private func endpoint(
        stop: StopTime?, fallback: String, event: StopTimelineTimePresentation.Event, alignment: HorizontalAlignment
    ) -> some View {
        let time = stop.map {
            StopTimelineTimePresentation(stop: $0, event: event, timeZoneIdentifier: presentation.timeZones.timeZoneIdentifier(for: $0))
        }
        let scheduled = stop.flatMap { event == .arrival ? $0.scheduledArrival : $0.scheduledDeparture }
        let showsScheduled = (time?.delayMinutes ?? 0) >= 5 && scheduled != nil
        return VStack(alignment: alignment, spacing: TrainTrackerSpacing.space4) {
            StationCodeText(station: stop?.station, fallbackName: fallback, alignment: alignment, foreground: .ttTextOnBrand)
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space6) {
                Text(time?.timeText ?? "Time unavailable")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ttTextOnBrand)
                if showsScheduled, let scheduled {
                    Text(JourneyPlanDateTimePresentation.time(
                        scheduled,
                        timeZoneIdentifier: stop.flatMap { presentation.timeZones.timeZoneIdentifier(for: $0) }
                            ?? TimeZone.autoupdatingCurrent.identifier
                    ))
                    .font(.footnote)
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(secondaryOnInk)
                    .accessibilityLabel("Timetable")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private func stubFields(ticket: LocalJourneyTicket?, boarding: PlatformBoardPresentation?) -> [TicketStubField] {
        let focus = presentation.progress.focusStop
        let platform: String? = switch presentation.platformGuidance {
        case .unavailable: nil
        default: presentation.platformGuidance.metricValue
        }
        var fields = [
            TicketStubField(
                id: "focus",
                label: focusStubLabel,
                value: focus.map { StationShortCode.code(for: $0.station) ?? $0.station.displayName }
                    ?? presentation.focusName
            ),
            TicketStubField(
                id: "time",
                label: presentation.timingLabel,
                value: presentation.focusTimeText ?? TicketStubField.unavailableValue,
                usesNumericDigits: true
            ),
            TicketStubField(
                id: "platform",
                label: (boarding.map { $0.previous != nil } ?? presentation.platformGuidance.isOfficialChange)
                    ? "\(presentation.platformNoun) changed" : presentation.platformNoun,
                value: boarding.map { $0.number ?? "View board" } ?? platform ?? TicketStubField.unavailableValue,
                usesNumericDigits: true
            ),
        ]
        if let coach = ticket?.details.coach, let seat = ticket?.details.seat,
           !dynamicTypeSize.isAccessibilitySize {
            fields.append(TicketStubField(id: "seat", label: "Seat", value: "\(coach) · \(seat)", usesNumericDigits: true))
        }
        return fields
    }

    /// A short stub label; the caption carries whether times are saved, estimated or live.
    private var focusStubLabel: String {
        TripObservationLabels.focus(presentation.progress)
    }

    /// Phase and countdown, where the platform came from, and the freshness of the data.
    private var captionText: String {
        var parts = [presentation.phaseTitle]
        if let countdown = presentation.countdownText { parts.append(countdown) }
        switch presentation.platformGuidance {
        case .official(_, let source, _):
            if let feed = presentation.platformSourceName {
                parts.append(source == .scheduled ? "\(presentation.platformNoun) last seen via \(feed)" : "\(presentation.platformNoun) via \(feed)")
            }
        case .likelyPlatform, .positioning:
            parts.append("\(presentation.platformNoun) is an estimate · check station displays")
        case .unavailable:
            if presentation.progress.phase == .upcoming || presentation.progress.phase == .departureSoon {
                parts.append("\(presentation.platformNoun) not in live feed · check station boards")
            }
        }
        parts.append(presentation.checkText)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(ticket: LocalJourneyTicket?) -> some View {
        let mapURL = presentation.stationMapURL
        if mapURL != nil || ticket != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TrainTrackerSpacing.space12) { actionButtons(mapURL: mapURL, ticket: ticket) }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) { actionButtons(mapURL: mapURL, ticket: ticket) }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func actionButtons(mapURL: URL?, ticket: LocalJourneyTicket?) -> some View {
        if let ticket {
            NavigationLink {
                LocalTicketDetailView(ticketID: ticket.id)
            } label: {
                Label("Show Ticket", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ttTextOnBrand)
            .foregroundStyle(Color.ttBackgroundBrand)
        }
        if let mapURL {
            Link(destination: mapURL) {
                Label("Station Map", systemImage: "map")
                    .frame(maxWidth: .infinity)
            }
            .heroSecondaryAction(tint: mood.glassTint)
            .accessibilityHint("Opens this station in Maps")
        }
    }
}

private extension View {
    /// A secondary action on the ink ticket: glass from iOS 26, tinted by the journey's mood when
    /// it has one; a bordered ivory button before that.
    @ViewBuilder
    func heroSecondaryAction(tint: Color?) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass(Glass.regular.tint((tint ?? Color.ttTextOnBrand).opacity(tint == nil ? 0.12 : 0.4))))
                .foregroundStyle(Color.ttTextOnBrand)
        } else {
            buttonStyle(.bordered).tint(tint ?? Color.ttTextOnBrand)
        }
    }
}
