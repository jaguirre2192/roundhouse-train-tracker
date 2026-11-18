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
        _departureDate = State(initialValue: suggestion.calendarLocalDeparture?.date(in: .gmt) ?? suggestion.departureDate ?? .now)
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
                    if suggestion.requiresDepartureTime {
                        DatePicker("Travel date", selection: $departureDate, displayedComponents: .date)
                            .environment(\.timeZone, reviewTimeZone)
                        CalendarReviewTimeField(date: $departureDate, confirmed: $departureTimeConfirmed, zone: reviewTimeZone)
                    } else {
                        DatePicker("Departure", selection: $departureDate)
                            .environment(\.timeZone, reviewTimeZone)
                    }
                    Text(suggestion.usesBoardingStationTime ? "Local time at the departure station" :
                            "Time zone: \(reviewTimeZone.identifier.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption)
                        .foregroundStyle(Color.ttTextSecondary)
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
                        onConfirm(suggestion.requestFromDatePicker(
                            origin: origin.trimmingCharacters(in: .whitespacesAndNewlines),
                            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
                            trainNumber: trainNumber,
                            value: departureDate
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
        if suggestion.usesBoardingStationTime { return .gmt }
        return suggestion.departureTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
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

private struct CalendarReviewTimeField: View {
    @Binding var date: Date
    @Binding var confirmed: Bool
    let zone: TimeZone
    @State private var isChoosing = false

    var body: some View {
        LabeledContent("Departure time") {
            Button(confirmed ? date.formatted(format) : "Set Time") { isChoosing = true }
            .accessibilityIdentifier("calendarDepartureTime")
            .popover(isPresented: $isChoosing) {
                CalendarReviewTimePicker(choice: date, format: format) { time in
                    date = time
                    confirmed = true
                    isChoosing = false
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var format: Date.FormatStyle {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = zone
        return format
    }
}

private struct CalendarReviewTimePicker: View {
    @State var choice: Date
    let format: Date.FormatStyle
    let onConfirm: (Date) -> Void

    var body: some View {
        VStack {
            DatePicker("Departure time", selection: $choice, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .environment(\.timeZone, format.timeZone)
                .labelsHidden()
            Button("Use \(choice.formatted(format))") { onConfirm(choice) }
                .buttonStyle(.borderedProminent)
                .tint(Color.ttBackgroundBrand)
                .accessibilityIdentifier("calendarApplyDepartureTime")
        }
        .padding()
    }
}
