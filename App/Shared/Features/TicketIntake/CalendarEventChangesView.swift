import SwiftUI
import TrainTrackerCore

/// A read-only section for the existing review Form. Values stack at every size so long
/// station names and accessibility text sizes share the same clear leading alignment.
struct CalendarEventChangesView: View {
    private let summary: CalendarEventChangeSummary

    init(candidate: CalendarJourneyCandidate, savedPlan: TrackedJourneyPlan?) {
        summary = CalendarEventChangeSummary(candidate: candidate, savedPlan: savedPlan)
    }

    fileprivate init(summary: CalendarEventChangeSummary) {
        self.summary = summary
    }

    var body: some View {
        Section {
            if let explanation = summary.explanation {
                Text(explanation.message)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            ForEach(summary.changes) { change in
                CalendarEventChangeRow(change: change)
            }
        } header: {
            Text("Compare journey details")
        } footer: {
            if !summary.changes.isEmpty {
                Text("Previously imported shows the details you confirmed. Calendar event shows what we can read now; check any differences before updating.")
            }
        }
        .trainTrackerRowSurface()
    }
}

private struct CalendarEventChangeRow: View {
    let change: CalendarEventChangeSummary.Change

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Text(change.field.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)
            value(label: "Previously imported", content: change.previouslyImported, isPrevious: true)
            value(label: "Calendar event", content: change.calendarEvent, isPrevious: false)
        }
        .padding(.vertical, TrainTrackerSpacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func value(label: String, content: CalendarEventChangeSummary.Value, isPrevious: Bool) -> some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
            Text(displayText(content, isPrevious: isPrevious))
                .font(.subheadline)
                .foregroundStyle(Color.ttTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func displayText(_ value: CalendarEventChangeSummary.Value, isPrevious: Bool) -> String {
        switch value {
        case .text(let text):
            if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
            return isPrevious ? "Not provided" : "Not found"
        case .timeZone(let identifier):
            return identifier?.replacingOccurrences(of: "_", with: " ") ?? "Not specified"
        case .allDay(let allDay):
            return allDay ? "All-day event" : "Timed event"
        case .departure(let date, let identifier, let includesTime):
            let zone = identifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            let style = Date.FormatStyle(date: .abbreviated, time: includesTime ? .shortened : .omitted, timeZone: zone)
            let formatted = date.formatted(style)
            guard includesTime else { return "All-day · \(formatted)" }
            let zoneLabel = identifier == nil ? "device time" : zone.abbreviation(for: date) ?? zone.identifier
            return "\(formatted) · \(zoneLabel)"
        }
    }
}

#if DEBUG
private enum CalendarEventChangesPreview {
    static var candidate: CalendarJourneyCandidate {
        let snapshot = CalendarEventSnapshot(
            eventIdentifier: "preview-event", calendarTitle: "Travel", title: "Amtrak 179: Washington → Boston",
            notes: nil, location: nil, startDate: Date(timeIntervalSince1970: 1_800_010_800),
            endDate: Date(timeIntervalSince1970: 1_800_014_400), isAllDay: false,
            timeZoneIdentifier: "America/New_York"
        )
        return CalendarJourneyCandidate(
            snapshot: snapshot,
            classification: CalendarJourneyClassification(
                confidence: .high, evidence: [], originGuess: "Washington",
                destinationGuess: "Boston", trainNumberGuess: "179"
            )
        )
    }

    static func summary(includeDetails: Bool) -> CalendarEventChangeSummary {
        let candidate = candidate
        let details = CalendarJourneyDetails(
            originName: "Washington", destinationName: "New York", trainNumber: "176",
            departureDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "America/New_York", isAllDay: false
        )
        return CalendarEventChangeSummary(
            candidate: candidate,
            previousSource: CalendarJourneySource(eventKey: candidate.id, revision: "previous", details: includeDetails ? details : nil)
        )
    }
}

#Preview("Calendar changes") {
    Form { CalendarEventChangesView(summary: CalendarEventChangesPreview.summary(includeDetails: true)) }
}

#Preview("Earlier import") {
    Form { CalendarEventChangesView(summary: CalendarEventChangesPreview.summary(includeDetails: false)) }
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
