import SwiftUI
import TrainTrackerCore

/// Shared review screen for both calendar candidates and share-extension imports. Nothing is
/// searched or tracked until the person confirms the route here.
struct TicketRouteReviewView: View {
    let suggestion: TicketRouteSuggestion
    let onConfirm: (TicketJourneySearchRequest) -> Void
    let updatesSavedJourney: Bool
    let calendarCandidate: CalendarJourneyCandidate?
    let savedCalendarPlan: TrackedJourneyPlan?
    let dismissesOnAction: Bool
    let onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var origin: String
    @State private var destination: String
    @State private var trainNumber: String
    @State private var departureDate: Date
    @State private var departureTimeConfirmed: Bool

    init(suggestion: TicketRouteSuggestion, updatesSavedJourney: Bool = false,
         calendarCandidate: CalendarJourneyCandidate? = nil, savedCalendarPlan: TrackedJourneyPlan? = nil,
         dismissesOnAction: Bool = true, onCancel: (() -> Void)? = nil,
         onConfirm: @escaping (TicketJourneySearchRequest) -> Void) {
        self.suggestion = suggestion
        self.updatesSavedJourney = updatesSavedJourney
        self.calendarCandidate = calendarCandidate
        self.savedCalendarPlan = savedCalendarPlan
        self.dismissesOnAction = dismissesOnAction
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _origin = State(initialValue: suggestion.originGuess ?? "")
        _destination = State(initialValue: suggestion.destinationGuess ?? "")
        _trainNumber = State(initialValue: suggestion.trainNumberGuess ?? "")
        _departureDate = State(initialValue: suggestion.departureDate ?? .now)
        _departureTimeConfirmed = State(initialValue: !suggestion.requiresDepartureTime)
    }

    private var canConfirm: Bool {
        TicketRouteReviewPolicy.canConfirm(
            origin: origin, destination: destination,
            requiresDepartureTime: suggestion.requiresDepartureTime,
            departureTimeConfirmed: departureTimeConfirmed
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if updatesSavedJourney, let calendarCandidate {
                    CalendarEventChangesView(candidate: calendarCandidate, savedPlan: savedCalendarPlan)
                }
                Section {
                    if updatesSavedJourney, calendarCandidate == nil {
                        Label("Calendar event changed", systemImage: "calendar.badge.exclamationmark")
                        Text("Review the new details. Tracking your selection will update the saved journey.")
                            .font(.subheadline)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                    LabeledContent("Source", value: suggestion.sourceDescription)
                    if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                    if let confidence = suggestion.confidence {
                        Label(confidenceLabel(confidence), systemImage: confidenceSymbol(confidence))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(confidence == .high ? Color.ttStatusOnTime : Color.ttStatusDelayed)
                    }
                }
                .trainTrackerRowSurface()

                Section {
                    TextField("Origin", text: $origin)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Origin station or city")
                    TextField("Destination", text: $destination)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Destination station or city")
                    DatePicker("Departure", selection: $departureDate)
                        .environment(\.timeZone, reviewTimeZone)
                        .accessibilityHint("Adjust if this isn't the right departure date or time")
                    Text("Time zone: \(reviewTimeZone.identifier.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
                    if suggestion.requiresDepartureTime {
                        Text("This is an all-day event. Set the train's departure time, then confirm it below.")
                            .font(.subheadline)
                        Toggle("Departure time checked", isOn: $departureTimeConfirmed)
                    }
                    TextField("Train number (optional)", text: $trainNumber)
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("Journey Details")
                } footer: {
                    Text("Correct anything that looks wrong. Nothing is searched until you confirm.")
                }
                .trainTrackerRowSurface()

                if !suggestion.evidence.isEmpty {
                    Section("Why we think this is a train journey") {
                        ForEach(suggestion.evidence, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(Color.ttTextSecondary)
                        }
                    }
                    .trainTrackerRowSurface()
                }
            }
            .formStyle(.grouped)
            .trainTrackerListCanvas()
            .navigationTitle("Review Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        if dismissesOnAction { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Find Trains") {
                        onConfirm(suggestion.journeySearchRequest(
                            origin: origin.trimmingCharacters(in: .whitespacesAndNewlines),
                            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                            trainNumber: trainNumber,
                            departureDate: departureDate
                        ))
                        if dismissesOnAction { dismiss() }
                    }
                    .disabled(!canConfirm)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var reviewTimeZone: TimeZone {
        suggestion.departureTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    private func confidenceLabel(_ confidence: TicketRouteConfidence) -> String {
        switch confidence {
        case .high: "Likely a train journey"
        case .medium: "Possible train journey — please check the route"
        }
    }

    private func confidenceSymbol(_ confidence: TicketRouteConfidence) -> String {
        switch confidence {
        case .high: "checkmark.seal.fill"
        case .medium: "questionmark.circle.fill"
        }
    }
}
