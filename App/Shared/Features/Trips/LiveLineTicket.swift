import SwiftUI
import TrainTrackerCore

/// Decisions for the ink live ticket that must stay truthful: when the live marker may show,
/// what the badge says, and how many stops remain.
enum LiveLineTicketPresentation {
    /// Live blue only appears for current realtime data: a recent successful check that did not
    /// fail since, realtime timing, and a train that is actually underway.
    static let liveDataWindow: TimeInterval = 5 * 60

    static func showsLiveMarker(
        status: TripPresentationStatus.Kind,
        phase: RailJourneyProgress.Phase,
        lastSuccessfulCheck: Date?,
        lastRefreshFailed: Bool,
        referenceDate: Date
    ) -> Bool {
        guard phase == .underway, !lastRefreshFailed, let lastSuccessfulCheck else { return false }
        guard [.onTime, .delayed, .estimated].contains(status) else { return false }
        let age = referenceDate.timeIntervalSince(lastSuccessfulCheck)
        return age >= 0 && age <= liveDataWindow
    }

    static func badgeText(for status: TripPresentationStatus, isConfirmed: Bool = true) -> String {
        // A status worked out from saved data names the trust word beside it.
        claimsLiveTiming(status.kind) && !isConfirmed ? "\(status.text) · \(JourneyTrust.saved.title)" : status.text
    }

    /// Kinds that state how the train is running now. Before this session's first successful
    /// check they describe saved data, so the badge says so and drops the alarm color.
    static func claimsLiveTiming(_ kind: TripPresentationStatus.Kind) -> Bool {
        kind == .delayed || kind == .onTime
    }

    /// Stops from the next one to the destination, inclusive. Zero only once the arrival is
    /// reported; a timetable that has run out gives no count, since the train may still be out.
    static func stopsLeft(in progress: RailJourneyProgress) -> Int? {
        if progress.phase == .ended { return progress.evidence.isArrivalConfirmed ? 0 : nil }
        guard let focus = progress.focusStop,
              let index = progress.stops.firstIndex(where: { $0.id == focus.id }) else { return nil }
        return progress.stops.count - index
    }

    /// The ticket header names the train ("Northeast Regional 171"); the operator is read by
    /// VoiceOver and shown on stubs, where there is room for both.
    static func serviceName(for trip: TrainTrip) -> String {
        let product = trip.product.trimmingCharacters(in: .whitespacesAndNewlines)
        return product.isEmpty ? trip.operatorName.trimmingCharacters(in: .whitespacesAndNewlines) : product
    }

    static func freshnessText(basis: String, lastSuccessfulCheck: Date?, lastRefreshFailed: Bool, referenceDate: Date) -> String {
        let freshness = TripFreshness(lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed)
        return "\(basis) · \(freshness.text(at: referenceDate, style: .compact))"
    }

    static func operatorLine(for trip: TrainTrip) -> String {
        let operatorName = trip.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = trip.product.trimmingCharacters(in: .whitespacesAndNewlines)
        if operatorName.isEmpty { return product }
        if product.isEmpty || product.localizedCaseInsensitiveContains(operatorName) {
            return product.isEmpty ? operatorName : product
        }
        return "\(operatorName) · \(product)"
    }
}

/// The live trip as an ink Line Ticket: station codes, a five-stop route line, a perforation and
/// a stub of the facts a passenger needs next.
struct LiveLineTicket: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    enum Density {
        /// My Trips on compact width and the journey focus: the full ticket.
        case full
        /// A split-view sidebar row: header, codes on a progress rail and the next step.
        case compact
        /// Discovery gives the full station names and prints the next call on its own stub.
        case featured
        /// Route and train identity; next-stop facts live in the tracking header above it.
        case routeSummary
    }

    let trip: TrainTrip
    var density: Density = .full
    var routeTimeZones: JourneyPlanRouteTimeZones?
    var timeZoneIdentifier: (StopTime) -> String? = { _ in nil }
    var lastSuccessfulCheck: Date?
    var lastRefreshFailed = false
    var selectedSegment: JourneyPlanSegment?
    var coach: String?
    var seat: String?
    var referenceDate: Date = .now
    /// False where a summary beside the ticket states the status and facts (My Trips): the
    /// ticket then keeps the route and its freshness line, without the badge and stub grid.
    var showsFacts = true
    /// On a journey resting over its map, the route line moves the map: tap a stop or slide.
    var linksToMap = false

    @State private var locatedCallZone: FeaturedCallClock.LocatedZone?
    private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

    var body: some View {
        let presentation = ActiveTripCardPresentation(
            trip: trip, routeTimeZones: routeTimeZones, referenceDate: referenceDate,
            lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed,
            selectedSegment: selectedSegment
        )
        let progress = presentation.effectiveProgress
        let status = presentation.status
        let isLive = LiveLineTicketPresentation.showsLiveMarker(
            status: status.kind, phase: progress.phase,
            lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed,
            referenceDate: referenceDate
        )
        let summary = RouteLineSummary(
            stops: progress.stops, focusStopID: progress.focusStop?.id, phase: progress.phase,
            referenceDate: referenceDate, showsLiveMarker: isLive,
            confirmedPassedStopIDs: progress.evidence.confirmedPassedStopIDs, isArrivalConfirmed: progress.evidence.isArrivalConfirmed,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let origin = progress.stops.first?.station ?? trip.origin
        let destination = progress.stops.last?.station ?? trip.destination
        let callClock = featuredClock(for: presentation)

        Group {
            if density != .full {
                CompactLineTicket(
                    density: density, origin: origin, destination: destination, summary: summary,
                    presentation: presentation, timeZoneIdentifier: timeZoneIdentifier, featuredTime: callClock
                ) {
                    header(status: status, isLive: isLive && density != .routeSummary)
                }
            } else {
                fullBody(status: status, isLive: isLive, summary: summary, origin: origin, destination: destination, presentation: presentation, progress: progress)
            }
        }
        .railUpdateSheen(updateKey: presentation.updateKey)
        .liveChangeFeedback(LiveChangeSignal(stop: presentation.guidanceStop, status: status,
                                             isConfirmed: lastSuccessfulCheck != nil && !lastRefreshFailed))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary(for: presentation, callClock: callClock))
        .task(id: callClock?.stationToLocate?.id) {
            guard let station = callClock?.stationToLocate,
                  let zone = await StationTimeZoneResolver.resolve(station), !Task.isCancelled else { return }
            locatedCallZone = .init(stationID: station.id, zone: zone)
        }
    }

    private func featuredClock(for presentation: ActiveTripCardPresentation) -> FeaturedCallClock? {
        guard density == .featured, let stop = presentation.guidanceStop else { return nil }
        let allowsLookup = !LaunchFixtures.isActive
        return FeaturedCallClock(stop: stop, boarding: presentation.isBeforeBoarding, suppliedZone: timeZoneIdentifier(stop),
                                 located: locatedCallZone,
                                 cachedZone: allowsLookup ? StationTimeZoneResolver.cached(for: stop.station.id) : nil,
                                 allowsLookup: allowsLookup)
    }

    /// The ticket is one accessibility element, so its label must carry the same passenger,
    /// timetable and check context as the visible route and stub.
    var accessibilitySummary: String {
        let presentation = ActiveTripCardPresentation(
            trip: trip, routeTimeZones: routeTimeZones, referenceDate: referenceDate,
            lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed,
            selectedSegment: selectedSegment
        )
        return spokenSummary(for: presentation, callClock: featuredClock(for: presentation))
    }

    private func spokenSummary(for presentation: ActiveTripCardPresentation, callClock: FeaturedCallClock?) -> String {
        tripAccessibilitySummary(
            trip,
            timeZoneIdentifier: presentation.guidanceStop.flatMap(timeZoneIdentifier)
                ?? routeTimeZones?.arrivalTimeZoneIdentifier,
            referenceDate: referenceDate,
            lastSuccessfulCheck: lastSuccessfulCheck,
            lastRefreshFailed: lastRefreshFailed,
            selectedSegment: selectedSegment, guidanceTimeText: callClock?.timeText
        )
    }

    private func fullBody(
        status: TripPresentationStatus, isLive: Bool, summary: RouteLineSummary,
        origin: Station?, destination: Station?,
        presentation: ActiveTripCardPresentation, progress: RailJourneyProgress
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                header(status: status, isLive: isLive)
                codes(origin: origin, destination: destination)
                RouteLineSummaryView(summary: summary, palette: .onInk, linksToMap: linksToMap)
            }
            .padding(LayoutMetrics.cardInset)

            TicketPerforation.onInk

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                if showsFacts {
                    TicketStubGrid(
                        fields: stubFields(presentation: presentation, progress: progress),
                        labelColor: secondaryOnInk,
                        valueColor: .ttTextOnBrand
                    )
                }
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    // The same mark the rail chip, the map and the summary strip carry.
                    JourneyTrustMark(
                        trust: JourneyTrust(card: presentation),
                        freshness: TripFreshness(lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed),
                        referenceDate: referenceDate, onInk: true
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        TicketCodeBars(seed: trip.id.rawValue)
                    }
                }
            }
            // The stub shares the leading edge of the codes and route above the perforation.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LayoutMetrics.cardInset)
            // A stub that carries only the freshness line is a slim strip.
            .padding(.vertical, showsFacts ? LayoutMetrics.cardInset : TrainTrackerSpacing.space12)
        }
        .liveTicketStyle()
        .overlay(alignment: .trailing) {
            // A finished journey is stamped where its destination is printed.
            // Only when the arrival is reported: a timetable that has run out stamps nothing.
            if progress.phase == .ended, !trip.isCancelled, !progress.isCancelled, !dynamicTypeSize.isAccessibilitySize,
               ArrivalEvidence.arrivalIsConfirmed(progress: progress),
               let destination, let arrival = progress.arrivalDate {
                ArrivalStamp(
                    place: StationShortCode.code(for: destination) ?? destination.displayName,
                    date: arrival,
                    timeZone: progress.stops.last.flatMap(timeZoneIdentifier).flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
                )
                .modifier(ArrivalStampStrike(journeyID: trip.id.rawValue))
                .padding(.trailing, LayoutMetrics.cardInset + TrainTrackerSpacing.space8)
                .offset(y: -TrainTrackerSpacing.space12)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func header(status: TripPresentationStatus, isLive: Bool) -> some View {
        if !showsFacts {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    serviceHeader(isLive: isLive).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    travelStamp
                }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    serviceHeader(isLive: isLive)
                    travelStamp
                }
            }
        } else if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                serviceHeader(isLive: isLive)
                TicketStatusBadge(status: status, isConfirmed: isConfirmed)
            }
        } else {
            // The train's name is never truncated for the badge: when both don't fit on one
            // line (a long service name or a "saved" qualifier) the badge moves beneath it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    serviceHeader(isLive: isLive).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: TrainTrackerSpacing.space8)
                    TicketStatusBadge(status: status, isConfirmed: isConfirmed)
                }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    serviceHeader(isLive: isLive)
                    TicketStatusBadge(status: status, isConfirmed: isConfirmed)
                }
            }
        }
    }

    @ViewBuilder
    private var travelStamp: some View {
        if let stamp = travelDateStamp, !dynamicTypeSize.isAccessibilitySize {
            Text(stamp)
                .font(.caption2.weight(.semibold).monospaced())
                .tracking(0.8)
                .foregroundStyle(Color.ttTextOnBrand.opacity(0.86))
                .padding(.horizontal, TrainTrackerSpacing.space6)
                .padding(.vertical, 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.ttTextOnBrand.opacity(0.42), lineWidth: 1)
                }
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private func serviceHeader(isLive: Bool) -> some View {
        HStack(spacing: TrainTrackerSpacing.space8) {
            if isLive {
                Circle()
                    .fill(Color.ttActionLiveOnInk)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Live")
            }
            Text(LiveLineTicketPresentation.serviceName(for: trip))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(secondaryOnInk)
        .layoutPriority(1)
    }

    private func codes(origin: Station?, destination: Station?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TrainTrackerSpacing.space16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: TrainTrackerSpacing.space16))
        return layout {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                StationCodeText(station: origin, fallbackName: "Origin", foreground: .ttTextOnBrand)
                if StationShortCode.code(for: origin) != nil {
                    Text(origin?.displayName ?? "")
                        .font(.footnote)
                        .foregroundStyle(secondaryOnInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: TrainTrackerSpacing.space2) {
                StationCodeText(
                    station: destination, fallbackName: trip.headsign,
                    alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, foreground: .ttTextOnBrand
                )
                if StationShortCode.code(for: destination) != nil {
                    Text(destination?.displayName ?? "")
                        .font(.footnote)
                        .foregroundStyle(secondaryOnInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }
        }
    }

    private func stubFields(presentation: ActiveTripCardPresentation, progress: RailJourneyProgress) -> [TicketStubField] {
        let next = presentation.guidanceStop
        let platform = presentation.platformValue
        let destination = progress.stops.last
        let arrival = destination.flatMap {
            StopTimelineTimePresentation(stop: $0, event: .arrival, timeZoneIdentifier: timeZoneIdentifier($0)).timeText
        }
        var fields = TicketStubFields.live(
            nextStop: next.map { StationShortCode.code(for: $0.station) ?? $0.station.displayName },
            platformNoun: presentation.platformLabel,
            platform: platform == "Not in feed" ? nil : platform,
            coach: coach,
            seat: seat,
            arrivalTime: arrival,
            destinationCode: destination.flatMap { StationShortCode.code(for: $0.station) },
            stopsLeft: LiveLineTicketPresentation.stopsLeft(in: progress)
        )
        if presentation.isBeforeBoarding, let nextField = fields.first {
            fields[0] = TicketStubField(id: nextField.id, label: "Board at", value: nextField.value)
        }
        return fields
    }

    private var isConfirmed: Bool {
        TripFreshness(lastSuccessfulCheck: lastSuccessfulCheck, lastRefreshFailed: lastRefreshFailed).isConfirmed
    }

    /// The departure date in the departure station's zone, such as "12 NOV".
    private var travelDateStamp: String? {
        guard let first = trip.stopTimes.first,
              let departure = first.scheduledDeparture ?? first.expectedDeparture ?? first.scheduledArrival else { return nil }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = timeZoneIdentifier(first).flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        return departure.formatted(style).uppercased()
    }
}

struct TicketStatusBadge: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: TripPresentationStatus
    var isConfirmed = true

    var body: some View {
        let color = LiveLineTicketPresentation.claimsLiveTiming(status.kind) && !isConfirmed
            ? Color.ttTextOnBrand.opacity(0.72)
            : Self.color(for: status.kind)
        HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                .accessibilityHidden(true)
            let text = LiveLineTicketPresentation.badgeText(for: status, isConfirmed: isConfirmed)
            Text(text)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                // A changing delay rolls to its new minutes rather than jumping.
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: text)
        }
        .foregroundStyle(color)
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.spokenText)\(isConfirmed ? "" : ", from saved details")")
    }

    static func color(for kind: TripPresentationStatus.Kind) -> Color {
        switch kind {
        case .onTime: .ttStatusOnTimeOnInk
        case .delayed: .ttStatusDelayedOnInk
        case .cancelled: .ttStatusCancelledOnInk
        case .arrived: .ttRouteOnInk
        case .scheduled, .estimated, .unavailable: Color.ttTextOnBrand.opacity(0.72)
        }
    }
}
