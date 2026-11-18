import SwiftUI

struct CalendarCandidateRow: View {
    let candidate: CalendarJourneyCandidate
    let disposition: CalendarImportDisposition

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(routeTitle)
                    .font(.headline)
                    .foregroundStyle(Color.ttTextPrimary)
                confidenceBadge
            }
            if let trainNumber = candidate.classification.trainNumberGuess {
                Text("Train \(trainNumber)")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            Text(eventDateLabel)
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
            if candidate.snapshot.isAllDay {
                Text("All-day event · departure time needed")
                    .font(.caption)
                    .foregroundStyle(Color.ttStatusDelayed)
            }
            Text(candidate.snapshot.calendarTitle)
                .font(.caption2)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .padding(.vertical, TrainTrackerSpacing.space4)
        .accessibilityElement(children: .combine)
    }

    private var routeTitle: String {
        if let origin = candidate.classification.originGuess,
           let destination = candidate.classification.destinationGuess {
            return "\(origin) → \(destination)"
        }
        return candidate.snapshot.title
    }

    private var confidenceBadge: some View {
        let isHigh = candidate.classification.confidence == .high
        return Text(statusTitle(isHigh: isHigh))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, TrainTrackerSpacing.space8)
            .padding(.vertical, TrainTrackerSpacing.space2)
            .background(
                statusColor.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(statusColor)
    }

    private var eventDateLabel: String {
        let zone = candidate.snapshot.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        let style = Date.FormatStyle(date: .abbreviated, time: candidate.snapshot.isAllDay ? .omitted : .shortened, timeZone: zone)
        return candidate.snapshot.startDate.formatted(style)
    }

    private var statusColor: Color {
        switch disposition {
        case .changed, .cancelled: .ttStatusDelayed
        case .alreadyAdded: .ttTextSecondary
        case .newJourney: candidate.classification.confidence == .high ? .ttStatusOnTime : .ttStatusDelayed
        }
    }
    private func statusTitle(isHigh: Bool) -> String {
        switch disposition {
        case .newJourney: isHigh ? "Likely" : "Possible"
        case .alreadyAdded: "Open saved journey"
        case .changed: "Changed · review needed"
        case .cancelled: "Canceled in Calendar"
        }
    }

}
