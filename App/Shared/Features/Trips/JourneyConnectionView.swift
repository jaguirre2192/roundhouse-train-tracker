import SwiftUI
import TrainTrackerCore

struct JourneyConnectionView: View {
    let connection: JourneyPlanStage.Connection
    let nextTrip: TrainTrip?
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space20) {
            Label("Connection", systemImage: "arrow.triangle.swap")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ttTextOperational)

            Text(connection.next.from.displayName)
                .font(.title.weight(.bold))
                .foregroundStyle(Color.ttTextPrimary)

            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
                Text("Next train · \(connection.next.serviceName ?? "Rail service")")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                if let departure {
                    HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space6) {
                        Text(JourneyExperienceClock.time(departure, zone: connection.next.from.timeZoneIdentifier))
                            .font(.largeTitle.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.ttTextPrimary)
                        if let zone = JourneyPlanDateTimePresentation.zoneSuffix(
                            departure, timeZoneIdentifier: connection.next.from.timeZoneIdentifier
                        ) {
                            Text(zone)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.ttTextSecondary)
                        }
                    }
                }
            }

            if let minutes = connection.estimatedMinutes ?? connection.timetableMinutes {
                Label(
                    minutes > 0 ? "\(minutes) min between trains" : "Connection may be missed",
                    systemImage: minutes > 0 ? "clock" : "exclamationmark.triangle"
                )
                .font(.headline)
                .foregroundStyle(minutes > 0 ? Color.ttTextPrimary : Color.ttStatusDelayed)
                Text(connection.estimatedMinutes == nil ? "Based on the planned timetable." : "Based on the last available estimates.")
                    .font(.caption)
                    .foregroundStyle(Color.ttTextSecondary)
            }

            if let timetable = connection.timetable {
                ConnectionTimetableView(timetable: timetable,
                                        showsAvailableInterval: (connection.estimatedMinutes ?? connection.timetableMinutes ?? 0) <= 0)
            }

            ForEach(connection.walks) { walk in
                Label {
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                        Text(walk.isStationChange ? "Change stations" : "Planned walk")
                            .font(.subheadline.weight(.semibold))
                        Text("\(walk.from.displayName) → \(walk.to.displayName)")
                            .font(.subheadline)
                        if let duration = walk.duration {
                            Text("Allow \(max(1, Int(ceil(duration / 60)))) min for the planned walk")
                                .font(.caption)
                        }
                    }
                } icon: {
                    Image(systemName: "figure.walk")
                }
                .foregroundStyle(Color.ttTextSecondary)
            }

            Text("Check station displays for your next platform. Connection times don’t include boarding cutoffs.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TrainTrackerSpacing.space24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ttBackgroundBrandSubtle, in: RoundedRectangle(cornerRadius: TrainTrackerRadius.card))
        .accessibilityElement(children: .contain)
    }

    private var departure: Date? {
        guard let nextTrip else { return connection.next.departure }
        return RailJourneyProgress(
            trip: nextTrip, referenceDate: referenceDate,
            boardingPlace: connection.next.from, alightingPlace: connection.next.to
        ).departureDate ?? connection.next.departure
    }
}
