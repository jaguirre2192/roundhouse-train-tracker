import SwiftUI
import TrainTrackerCore

/// A saved next step; active transfer windows and risks remain owned by JourneyPlanFocusView.
struct JourneyPlanUpcomingTransferPresentation {
    let next: JourneyPlanSegment
    let walks: [JourneyPlanSegment]
    let timetable: ConnectionTimetable?

    var stationName: String { next.from.displayName }
    var serviceName: String { next.serviceName ?? "Next train" }
    var departureText: String? {
        guard let departure = next.departure else { return nil }
        let zone = next.from.timeZoneIdentifier
        let day = JourneyPlanDateTimePresentation.date(departure, timeZoneIdentifier: zone)
        let time = JourneyPlanDateTimePresentation.labeledTime(departure, timeZoneIdentifier: zone)
        return "Timetable departure \(day) · \(time)"
    }

    init?(stage: JourneyPlanStage, trips: [TrainTrip], referenceDate: Date) {
        guard stage.kind == .rail, stage.connection == nil,
              let focus = stage.focusSegment, let currentTrip = stage.focusTrip,
              focus.to.kind == .station,
              !Self.hasCancelledEndpoint(currentTrip, segment: focus, at: referenceDate),
              let segments = stage.direction.selectedSegments,
              Set(segments.map(\.id)).count == segments.count,
              let index = segments.firstIndex(where: { $0.id == focus.id }) else { return nil }

        var station = focus.to
        var plannedWalks: [JourneyPlanSegment] = []
        for segment in segments.dropFirst(index + 1) {
            guard JourneyTransferStation.matches(segment.from, station) else { return nil }
            if segment.kind == .rail {
                guard segment.from.kind == .station, !segment.isStationChange,
                      segment.departure.map({ $0 > referenceDate }) ?? true else { return nil }
                if let id = segment.resolvedTripID {
                    let matches = trips.filter { $0.id == id }
                    guard matches.count < 2 else { return nil }
                    if let trip = matches.first, Self.hasCancelledEndpoint(trip, segment: segment, at: referenceDate) {
                        return nil
                    }
                }
                next = segment
                walks = plannedWalks
                let arrival = JourneyRecoveryRequest.progress(focus, trips: trips, at: referenceDate)?.stops.last
                let departure = JourneyRecoveryRequest.progress(segment, trips: trips, at: referenceDate)?.stops.first
                timetable = ConnectionTimetable(previous: focus, next: segment, walks: plannedWalks,
                                                arrival: arrival, departure: departure)
                return
            }
            plannedWalks.append(segment)
            station = segment.to
        }
        return nil
    }

    private static func hasCancelledEndpoint(_ trip: TrainTrip, segment: JourneyPlanSegment, at date: Date) -> Bool {
        let progress = RailJourneyProgress(
            trip: trip, referenceDate: date, boardingPlace: segment.from, alightingPlace: segment.to
        )
        return trip.isCancelled || progress.stops.first?.isCancelled == true || progress.stops.last?.isCancelled == true
    }
}

struct JourneyPlanUpcomingTransferView: View {
    let transfer: JourneyPlanUpcomingTransferPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
            Text("Planned change at \(transfer.stationName)")
                .font(.headline)
                .foregroundStyle(Color.ttTextPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(transfer.serviceName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ttTextPrimary)

            if let departure = transfer.departureText {
                Text(departure)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.ttTextSecondary)
            }

            if let walk = transfer.walks.first {
                Text("Planned walk from \(walk.from.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }

            if let timetable = transfer.timetable {
                ConnectionTimetableView(timetable: timetable)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("upcomingJourneyConnection")
    }
}
