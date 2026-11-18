import SwiftUI

/// Changes stay in this sheet's draft until Done validates and applies them once.
struct CalendarImportOptionsView: View {
    let store: CalendarImportStore
    let includingEventKeys: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CalendarImportOptions
    @State private var isApplying = false
    @State private var saveError: String?

    init(store: CalendarImportStore, includingEventKeys: Set<String> = []) {
        self.store = store
        self.includingEventKeys = includingEventKeys
        _draft = State(initialValue: store.options)
    }

    var body: some View {
        NavigationStack {
            Form {
                dateSection
                allCalendarsSection
                ForEach(sourceTitles, id: \.self) { source in
                    Section(source) {
                        ForEach(store.calendars.filter { $0.sourceTitle == source }) { calendar in
                            Toggle(calendar.title, isOn: calendarSelection(calendar.id))
                                .accessibilityIdentifier("calendar-options-source-\(calendar.id)")
                        }
                    }
                    .trainTrackerRowSurface()
                }
                if unavailableSelectionCount > 0 {
                    Section {
                        Text("Some selected calendars are no longer available on this device. They remain selected if they return.")
                            .font(.footnote)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                    .trainTrackerRowSurface()
                }
            }
            .formStyle(.grouped)
            .trainTrackerListCanvas()
            .disabled(isApplying)
            .navigationTitle("Calendar Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isApplying)
                        .accessibilityIdentifier("calendar-options-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard !isApplying else { return }
                        isApplying = true
                        Task { await applyDraft() }
                    }
                    .disabled(isApplying || validationMessage != nil)
                    .accessibilityIdentifier("calendar-options-done")
                }
            }
            .onChange(of: draft.datePreset) { _, preset in
                guard preset == .custom else { return }
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: .now)
                if draft.customStartDate == nil { draft.customStartDate = start }
                if draft.customEndDate == nil {
                    draft.customEndDate = calendar.date(byAdding: .day, value: 29, to: start)
                }
            }
            .alert("Couldn't apply options", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "Please try again.")
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    private var dateSection: some View {
        Section {
            Picker("Date Range", selection: $draft.datePreset) {
                ForEach(CalendarImportOptions.DatePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .accessibilityIdentifier("calendar-options-date-range")
            if draft.datePreset == .custom {
                DatePicker("Start Date", selection: customDate(\.customStartDate), displayedComponents: .date)
                    .accessibilityIdentifier("calendar-options-start-date")
                DatePicker("End Date", selection: customDate(\.customEndDate), displayedComponents: .date)
                    .accessibilityIdentifier("calendar-options-end-date")
                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.ttStatusDelayed)
                        .accessibilityIdentifier("calendar-options-date-error")
                }
            }
        } header: {
            Text("Dates")
        } footer: {
            Text(draft.datePreset == .custom
                ? "Both dates are included. Choose up to 366 days."
                : draft.dateRangeSummary)
        }
        .trainTrackerRowSurface()
    }

    private var allCalendarsSection: some View {
        Section {
            Toggle("All Calendars", isOn: Binding(
                get: { draft.selectedCalendarIDs == nil },
                set: { draft.selectedCalendarIDs = $0 ? nil : Set(store.calendars.map(\.id)) }
            ))
            .accessibilityIdentifier("calendar-options-all-calendars")
            if store.calendars.isEmpty {
                Text("No calendars are available. Calendar access and accounts are managed in Settings.")
                    .font(.footnote)
                    .foregroundStyle(Color.ttTextSecondary)
            }
        } header: {
            Text("Calendars")
        } footer: {
            Text(draft.selectedCalendarIDs?.isEmpty == true
                ? "No calendars selected. Select a calendar to see its events."
                : "All Calendars includes calendars you add later. Selecting individual calendars limits which events Roundhouse reads.")
        }
        .trainTrackerRowSurface()
    }

    private var sourceTitles: [String] {
        Set(store.calendars.map(\.sourceTitle)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var unavailableSelectionCount: Int {
        draft.selectedCalendarIDs?.subtracting(Set(store.calendars.map(\.id))).count ?? 0
    }

    private var validationMessage: String? {
        do {
            _ = try draft.dateInterval()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func calendarSelection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.selectedCalendarIDs?.contains(id) ?? true },
            set: { selected in
                var ids = draft.selectedCalendarIDs ?? Set(store.calendars.map(\.id))
                if selected { ids.insert(id) } else { ids.remove(id) }
                draft.selectedCalendarIDs = ids
            }
        )
    }

    private func customDate(_ keyPath: WritableKeyPath<CalendarImportOptions, Date?>) -> Binding<Date> {
        Binding(
            get: { draft[keyPath: keyPath] ?? Calendar.current.startOfDay(for: .now) },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    private func applyDraft() async {
        do {
            try await store.updateOptions(draft, includingEventKeys: includingEventKeys)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isApplying = false
        }
    }
}
