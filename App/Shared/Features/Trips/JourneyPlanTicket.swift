import SwiftUI
import TrainTrackerCore

/// A saved journey as one ink ticket: where it runs, the days it covers, and when each direction
/// leaves and arrives. It heads the journey screen whenever no single train's ticket does.
struct JourneyPlanTicket: View {
    let plan: TrackedJourneyPlan
    let presentation: JourneyPlanPresentation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    Text(isRoundTrip ? "Round Trip" : "One Way")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(secondaryOnInk)
                    Spacer(minLength: 0)
                    if let stamp = dateStamp, !dynamicTypeSize.isAccessibilitySize {
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
                            .accessibilityHidden(true)
                    }
                }
                places
            }
            .padding(LayoutMetrics.cardInset)

            TicketPerforation.onInk

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
                ForEach(presentation.directions) { direction in
                    directionRow(direction)
                }
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    Label(trackedText, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(secondaryOnInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        TicketCodeBars(seed: plan.id.uuidString)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutMetrics.cardInset)
        }
        .liveTicketStyle()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("journeyPlanTicket")
    }

    private var isRoundTrip: Bool { plan.returnDirection != nil }

    /// The two ends, set like the station names on a ticket. Side by side while both names fit
    /// on one line; otherwise one above the other, so a name is never broken across lines.
    private var places: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                Text(plan.origin.displayName).lineLimit(1).fixedSize()
                Spacer(minLength: TrainTrackerSpacing.space4)
                arrow
                Spacer(minLength: TrainTrackerSpacing.space4)
                Text(plan.destination.displayName).lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(plan.origin.displayName)
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8) {
                    arrow
                    Text(plan.destination.displayName)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.title.weight(.bold))
        .foregroundStyle(Color.ttTextOnBrand)
    }

    private var arrow: some View {
        Image(systemName: isRoundTrip ? "arrow.left.arrow.right" : "arrow.right")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.ttRouteOnInk)
            .accessibilityLabel(isRoundTrip ? "and back from" : "to")
    }

    private func directionRow(_ direction: JourneyPlanDirectionPresentation) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text(direction.title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer(minLength: TrainTrackerSpacing.space8)
                Text(direction.departureDateText)
                    .font(.caption)
            }
            .foregroundStyle(secondaryOnInk)
            // Leaves, then arrives, each in its own station's time.
            ViewThatFits(in: .horizontal) {
                times(direction, axis: .horizontal)
                times(direction, axis: .vertical)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(direction.title), \(JourneySearchCopy.Plan.departs(date: direction.departureDateText, time: direction.departureTimeText)), \(JourneySearchCopy.Plan.arrives(date: direction.arrivalDateText, time: direction.arrivalTimeText))")
    }

    private func times(_ direction: JourneyPlanDirectionPresentation, axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space8))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: TrainTrackerSpacing.space2))
        return layout {
            Text(direction.departureTimeText)
            if axis == .horizontal {
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ttRouteOnInk)
                    .accessibilityHidden(true)
            }
            Text(direction.arrivalTimeText)
        }
        .font(.headline)
        .monospacedDigit()
        .foregroundStyle(Color.ttTextOnBrand)
        .lineLimit(1)
        .fixedSize(horizontal: axis == .horizontal, vertical: false)
    }

    /// "NOV 13" or "NOV 13 – NOV 14", in the origin's own days.
    private var dateStamp: String? {
        guard let first = presentation.directions.first, let last = presentation.directions.last else { return nil }
        func day(_ date: Date, zone: String) -> String {
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.timeZone = TimeZone(identifier: zone) ?? .autoupdatingCurrent
            return date.formatted(style).uppercased()
        }
        let start = day(first.departure, zone: first.departureTimeZoneIdentifier)
        let end = day(last.arrival, zone: last.arrivalTimeZoneIdentifier)
        return start == end ? start : "\(start) – \(end)"
    }

    private var trackedText: String {
        let children = presentation.directions.flatMap(\.children)
        let tracked = children.filter { $0.trip != nil }.count
        if children.isEmpty { return "No trains tracked" }
        if tracked == children.count { return tracked == 1 ? "1 train tracked" : "\(tracked) trains tracked" }
        return "\(tracked) of \(children.count) trains tracked"
    }
}

/// One direction's trains as a rail: a node for each train, the line between them the change.
/// The node says where that train is in its run; the status beside it says how it is running.
struct JourneyLegList: View {
    let children: [JourneyPlanChildPresentation]
    let routeTimeZones: JourneyPlanRouteTimeZones
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                let isLast = index == children.count - 1
                if let trip = child.trip {
                    NavigationLink {
                        TripDetailView(trip: trip, routeTimeZones: routeTimeZones)
                    } label: {
                        JourneyLegRow(trip: trip, routeTimeZones: routeTimeZones, referenceDate: referenceDate, isLast: isLast)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this train's stops and live map")
                } else {
                    JourneyLegRow(trip: nil, routeTimeZones: routeTimeZones, referenceDate: referenceDate, isLast: isLast)
                }
            }
        }
        .padding(.horizontal, LayoutMetrics.cardInset)
        .padding(.top, LayoutMetrics.cardInset)
        .padding(.bottom, TrainTrackerSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trainTrackerSurface(radius: TrainTrackerRadius.group)
    }
}

private struct JourneyLegRow: View {
    let trip: TrainTrip?
    let routeTimeZones: JourneyPlanRouteTimeZones
    let referenceDate: Date
    let isLast: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
            rail
            content
                .padding(.bottom, TrainTrackerSpacing.space16)
            if trip != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ttTextSecondary)
                    .padding(.top, TrainTrackerSpacing.space4)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var progress: RailJourneyProgress? {
        trip.map { RailJourneyProgress(trip: $0, referenceDate: referenceDate) }
    }


    /// The node, then the line down to the next train.
    private var rail: some View {
        VStack(spacing: TrainTrackerSpacing.space4) {
            node
                .frame(width: 18, height: 18)
                .padding(.top, 2)
            if !isLast {
                Capsule()
                    .fill(progress?.evidence.isArrivalConfirmed == true ? Color.ttRouteActive : Color.ttRoutePassed)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, TrainTrackerSpacing.space4)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var node: some View {
        if let trip, trip.isCancelled {
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ttStatusCancelled)
        } else if trip == nil {
            Image(systemName: "minus.circle").foregroundStyle(Color.ttTextSecondary)
        } else if progress?.evidence.isArrivalConfirmed == true {
            Circle().fill(Color.ttRouteActive)
        } else if progress?.evidence.observedFocusStopID != nil {
            Circle().fill(Color.ttBackgroundElevated)
                .overlay { Circle().strokeBorder(Color.ttRouteActive, lineWidth: 5) }
        } else {
            Circle().fill(Color.ttBackgroundElevated)
                .overlay { Circle().strokeBorder(Color.ttTextBrand, lineWidth: 3) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let trip {
            let schedule = TripRowSchedulePresentation(trip: trip, routeTimeZones: routeTimeZones)
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                Text("\(trip.origin?.displayName ?? "Origin") → \(trip.destination?.displayName ?? "Destination")")
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(serviceLine(trip, schedule: schedule))
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                timing(trip, schedule: schedule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                Text(JourneySearchCopy.Plan.train)
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                Text(JourneySearchCopy.Plan.noLongerTracked)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func timing(_ trip: TrainTrip, schedule: TripRowSchedulePresentation) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedTiming(trip, schedule: schedule)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                    departure(schedule)
                    TripStatusLabel(trip: trip).font(.caption)
                }
                .fixedSize(horizontal: true, vertical: true)
                stackedTiming(trip, schedule: schedule)
            }
        }
    }

    private func stackedTiming(_ trip: TrainTrip, schedule: TripRowSchedulePresentation) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
            // Keep the station-local time and zone intact, allowing a line break between
            // their words instead of giving the entire navigation row an oversized minimum.
            departure(schedule, wraps: true)
            TripStatusLabel(trip: trip).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func departure(_ schedule: TripRowSchedulePresentation, wraps: Bool = false) -> some View {
        Group {
            if let text = schedule.departureTimeText {
                Text(text)
            } else {
                Text(schedule.departureDate, style: .time)
            }
        }
        .font(.headline.monospacedDigit())
        .foregroundStyle(Color.ttTextPrimary)
        .lineLimit(wraps ? nil : 1)
        .fixedSize(horizontal: !wraps, vertical: wraps)
    }

    /// "Eurostar 9401 · Fri, Nov 13"
    private func serviceLine(_ trip: TrainTrip, schedule: TripRowSchedulePresentation) -> String {
        let date = schedule.serviceDateText
            ?? schedule.departureDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let name = LiveLineTicketPresentation.serviceName(for: trip)
        return name.isEmpty ? date : "\(name) · \(date)"
    }
}
