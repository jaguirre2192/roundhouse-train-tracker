import SwiftUI
import TrainTrackerCore

struct TripRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let trip: TrainTrip
    let routeTimeZones: JourneyPlanRouteTimeZones?

    init(
        trip: TrainTrip,
        routeTimeZones: JourneyPlanRouteTimeZones? = nil
    ) {
        self.trip = trip
        self.routeTimeZones = routeTimeZones
    }

    private var schedule: TripRowSchedulePresentation {
        TripRowSchedulePresentation(trip: trip, routeTimeZones: routeTimeZones)
    }

    var body: some View {
        Group {
            if dynamicTypeSize >= .xxLarge {
                largeTextLayout
            } else {
                // A station-zone time ("3:41 AM GMT+1") beside a long status badge can be wider
                // than a narrow card; the stacked layout keeps everything on screen.
                ViewThatFits(in: .horizontal) {
                    standardLayout
                    largeTextLayout
                }
            }
        }
        // ViewThatFits centers a layout narrower than the row; keep rows on the leading edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, TrainTrackerSpacing.space12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The status badge sits under the route so a long badge never squeezes station names.
    private var standardLayout: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
            trainIcon

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                routeSummary
                TripStatusLabel(trip: trip)
                    .font(.caption)
            }
            .layoutPriority(1)

            Spacer(minLength: TrainTrackerSpacing.space12)

            departureTime
                .font(.headline.monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var largeTextLayout: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
            trainIcon

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                routeSummary

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space12) {
                        stackedDepartureTime

                        Spacer(minLength: 0)

                        TripStatusLabel(trip: trip)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                        stackedDepartureTime
                        TripStatusLabel(trip: trip)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var stackedDepartureTime: some View {
        departureTime
            .font(.headline.monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
    }

    private var trainIcon: some View {
        Image(TrainTrackerSymbol.train)
            .font(.title3)
            .foregroundStyle(Color.ttRouteActive)
            .frame(width: 32, height: 32)
            .background(
                Color.ttBackgroundBrandSubtle,
                in: RoundedRectangle(cornerRadius: TrainTrackerRadius.icon, style: .continuous)
            )
    }

    private var routeSummary: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(routeTitle)
                .font(.headline)
                .foregroundStyle(Color.ttTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            serviceDate
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        }
    }

    private var routeTitle: String {
        "\(trip.origin?.displayName ?? "Origin") → \(trip.destination?.displayName ?? "Destination")"
    }

    @ViewBuilder
    private var departureTime: some View {
        if let departureTimeText = schedule.departureTimeText {
            Text(departureTimeText)
        } else {
            Text(schedule.departureDate, style: .time)
        }
    }

    @ViewBuilder
    private var serviceDate: some View {
        if let serviceDateText = schedule.serviceDateText {
            Text(serviceDateText)
        } else {
            // The scheduled departure, like the time beside it; the service date is a
            // UTC midnight that reads as the day before anywhere west of Greenwich.
            Text(schedule.departureDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }
}

struct TripRowSchedulePresentation {
    let departureDate: Date
    let serviceDate: Date
    let departureTimeText: String?
    let serviceDateText: String?

    init(
        trip: TrainTrip,
        routeTimeZones: JourneyPlanRouteTimeZones? = nil
    ) {
        let departureDate = trip.stopTimes.first?.scheduledDeparture ?? trip.serviceDate
        let serviceDate = trip.serviceDate
        self.departureDate = departureDate
        self.serviceDate = serviceDate
        departureTimeText = routeTimeZones.map {
            JourneyPlanDateTimePresentation.labeledTime(
                departureDate,
                timeZoneIdentifier: $0.departureTimeZoneIdentifier
            )
        }
        serviceDateText = routeTimeZones.map {
            JourneyPlanDateTimePresentation.date(
                departureDate,
                timeZoneIdentifier: $0.departureTimeZoneIdentifier
            )
        }
    }
}
