import SwiftUI
import UIKit
import EventKit
import TrainTrackerCore

/// Calendar reads stay local. Find Train and reviewed details continue in the shared import
/// review, which searches only the chosen route/time and still requires Track Journey.
struct CalendarImportView: View {
    /// The Bool is true when the person edited details, so those edits replace an older draft.
    let onReview: (TicketRouteSuggestion, Bool) -> Void

    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var store: CalendarImportStore
    @State private var selectedCandidate: CalendarJourneyCandidate?
    @State private var openedPlan: TrackedJourneyPlan?
    @State private var removalCandidate: CalendarJourneyCandidate?
    @State private var removalError: String?
    @State private var showsOptions = false

    init(store: CalendarImportStore = CalendarImportStore(), onReview: @escaping (TicketRouteSuggestion, Bool) -> Void) {
        _store = State(initialValue: store)
        self.onReview = onReview
    }

    private var importedEventKeys: Set<String> {
        Set(planLibrary.plans.compactMap { $0.calendarSource?.eventKey })
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import from Calendar")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsOptions = true } label: {
                            Label("Calendars and Dates", systemImage: "line.3.horizontal.decrease")
                        }
                        .accessibilityIdentifier("calendar-import-options")
                    }
                }
                .sheet(item: $selectedCandidate) { candidate in
                    TicketRouteReviewView(
                        suggestion: candidate.routeSuggestion,
                        updatesSavedJourney: savedPlan(for: candidate) != nil,
                        calendarCandidate: candidate,
                        savedCalendarPlan: savedPlan(for: candidate),
                        onConfirm: { request in
                            onReview(TicketRouteSuggestion(reviewed: request, from: candidate.routeSuggestion), true)
                            dismiss()
                        }
                    )
                }
                .sheet(isPresented: $showsOptions) {
                    CalendarImportOptionsView(store: store, includingEventKeys: importedEventKeys)
                }
                .navigationDestination(item: $openedPlan) { plan in
                    JourneyPlanDetailView(plan: plan, planLibrary: planLibrary)
                }
                .task { await store.beginImport(includingEventKeys: importedEventKeys) }
                .onChange(of: store.state) { _, state in
                    if case let .loaded(loaded) = state { planLibrary.adoptStableCalendarKeys(for: loaded) }
                }
        }
        .presentationDetents([.large])
        .onDisappear { store.reset() }
        .onChange(of: scenePhase) { old, new in
            if old != .active && new == .active {
                Task { await store.refresh(includingEventKeys: importedEventKeys) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await store.refresh(includingEventKeys: importedEventKeys) }
        }
        .confirmationDialog(
            "Remove the canceled journey?",
            isPresented: Binding(get: { removalCandidate != nil }, set: { if !$0 { removalCandidate = nil } }),
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { candidate in
            Button("Remove Saved Journey", role: .destructive) { removeCancelledJourney(candidate) }
        } message: { _ in
            Text("This removes the journey from Roundhouse. Trains used by other saved journeys stay tracked. Your Calendar event is unchanged.")
        }
        .alert("Couldn't remove journey", isPresented: Binding(
            get: { removalError != nil }, set: { if !$0 { removalError = nil } }
        )) {
            Button("OK") { removalError = nil }
        } message: { Text(removalError ?? "Please try again.") }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .requestingAccess:
            TicketIntakeLoadingView(title: "Requesting calendar access…")
        case .loading:
            TicketIntakeLoadingView(title: "Looking for train journeys…")
        case let .loaded(candidates):
            candidateList(candidates)
        case .empty:
            ContentUnavailableView {
                Label("No train journeys found", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("\(store.options.calendarSummary(availableCalendars: store.calendars)) · \(store.options.dateRangeSummary)")
                Text("Choose other calendars or dates to look for more journeys.")
            } actions: {
                Button("Calendars and Dates") { showsOptions = true }
                Button("Refresh") { Task { await store.refresh(includingEventKeys: importedEventKeys) } }
            }
        case .denied:
            deniedState(restricted: false)
        case .restricted:
            deniedState(restricted: true)
        case let .error(message):
            ContentUnavailableView {
                Label("Couldn't read your calendar", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await store.beginImport(includingEventKeys: importedEventKeys) } }
            }
        }
    }

    private func candidateList(_ candidates: [CalendarJourneyCandidate]) -> some View {
        let needsReview = candidates.filter { disposition(for: $0) == .changed || ($0.snapshot.isCancelled && savedPlan(for: $0) != nil) }
        let available = candidates.filter { disposition(for: $0) == .newJourney }
        let added = candidates.filter { disposition(for: $0) == .alreadyAdded }
        let cancelled = candidates.filter { $0.snapshot.isCancelled && savedPlan(for: $0) == nil }
        return List {
            Section {
                Button { showsOptions = true } label: {
                    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                        Text(store.options.calendarSummary(availableCalendars: store.calendars))
                            .font(.subheadline.weight(.medium))
                        Text(store.options.dateRangeSummary)
                            .font(.caption)
                            .foregroundStyle(Color.ttTextSecondary)
                    }
                }
                .accessibilityHint("Choose calendars and dates to import")
            } footer: {
                Text("Find Train searches using the selected route and time. Review Details lets you edit them first.")
            }
            if !needsReview.isEmpty {
                Section("Needs review") {
                    ForEach(needsReview) { candidate in candidateRow(candidate) }
                }
            }
            if !available.isEmpty {
                Section("Journeys") {
                    ForEach(available) { candidate in candidateRow(candidate) }
                }
            }
            if !added.isEmpty {
                Section("Already added") {
                    ForEach(added) { candidate in candidateRow(candidate) }
                }
            }
            if !cancelled.isEmpty {
                Section("Canceled in Calendar") {
                    ForEach(cancelled) { candidate in
                        CalendarCandidateRow(candidate: candidate, disposition: .cancelled)
                    }
                }
            }
        }
        .trainTrackerListCanvas()
        .refreshable { await store.refresh(includingEventKeys: importedEventKeys) }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: CalendarJourneyCandidate) -> some View {
        if disposition(for: candidate) == .newJourney, CalendarCandidateActionPolicy.canFindDirectly(candidate) {
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
                CalendarCandidateRow(candidate: candidate, disposition: .newJourney)
                // Same action pair as Calendar suggestions on My Trips: one bordered, one text.
                HStack(spacing: TrainTrackerSpacing.space16) {
                    Button("Find Train") { findTrain(candidate) }
                        .buttonStyle(.bordered)
                    Button("Review Details") { selectedCandidate = candidate }
                        .buttonStyle(.borderless)
                }
            }
            .trainTrackerRowSurface()
        } else {
            Button {
                switch disposition(for: candidate) {
                case .alreadyAdded: openedPlan = savedPlan(for: candidate)
                case .cancelled: removalCandidate = candidate
                default: selectedCandidate = candidate
                }
            } label: {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    CalendarCandidateRow(candidate: candidate, disposition: disposition(for: candidate))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ttTextSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(disposition(for: candidate) == .alreadyAdded ? "Opens your saved journey" : "Reviews the calendar event")
            .trainTrackerRowSurface()
        }
    }

    private func findTrain(_ candidate: CalendarJourneyCandidate) {
        guard CalendarCandidateActionPolicy.canFindDirectly(candidate) else { return }
        onReview(candidate.routeSuggestion, false)
        dismiss()
    }

    private func savedPlan(for candidate: CalendarJourneyCandidate) -> TrackedJourneyPlan? {
        planLibrary.plan(importedFrom: candidate.id)
    }

    private func disposition(for candidate: CalendarJourneyCandidate) -> CalendarImportDisposition {
        CalendarImportDisposition(candidate: candidate, savedPlan: savedPlan(for: candidate))
    }

    private func removeCancelledJourney(_ candidate: CalendarJourneyCandidate) {
        guard let plan = savedPlan(for: candidate) else { return }
        do {
            try planLibrary.removePlanAndStopTrackingChildren(id: plan.id)
            removalCandidate = nil
        } catch {
            removalError = "The saved journey couldn't be removed. Please try again."
        }
    }

    private func deniedState(restricted: Bool) -> some View {
        ContentUnavailableView {
            Label(restricted ? "Calendar access is restricted" : "Calendar access is off", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text(restricted
                 ? "This device's settings don't allow Roundhouse to read the calendar."
                 : "Turn on calendar access in Settings to import train journeys from your events.")
        } actions: {
            if !restricted {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
            }
        }
    }
}
