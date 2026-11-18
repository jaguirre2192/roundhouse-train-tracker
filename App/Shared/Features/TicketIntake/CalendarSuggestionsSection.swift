import EventKit
import SwiftUI
import UIKit

/// Opt-in Calendar suggestions on My Trips. While off, Calendar is never read and permission is
/// never requested; enabling is the only action that may show the system permission prompt.
struct CalendarSuggestionsSection: View {
    let referenceDate: Date
    let onReview: (CalendarJourneyCandidate) -> Void

    @Environment(JourneyPlanLibrary.self) private var planLibrary
    @Environment(JourneyIntakeModel.self) private var intake
    @State private var presentsImporter = false
    @State private var pendingImporterReview: (suggestion: TicketRouteSuggestion, isEdited: Bool)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var store: CalendarSuggestionStore
    @State private var showsOptions = false
    @State private var showsIntroduction: Bool

    init(
        store: CalendarSuggestionStore? = nil,
        referenceDate: Date = .now,
        onReview: @escaping (CalendarJourneyCandidate) -> Void
    ) {
        // My Trips redraws this section every 30 seconds; a default argument would build (and
        // discard) a new store and Calendar client on every redraw, so share one lazily.
        let store = store ?? Self.defaultStore
        _store = State(initialValue: store)
        _showsIntroduction = State(initialValue: !store.isIntroductionDismissed)
        self.referenceDate = referenceDate
        self.onReview = onReview
    }

    @MainActor private static let defaultStore = CalendarSuggestionStore()

    private var candidates: [CalendarJourneyCandidate] {
        store.candidates(savedPlans: planLibrary.plans).sorted { lhs, rhs in
            let lhsIsPast = lhs.snapshot.endDate <= referenceDate
            let rhsIsPast = rhs.snapshot.endDate <= referenceDate
            if lhsIsPast != rhsIsPast { return !lhsIsPast }
            if lhs.snapshot.startDate != rhs.snapshot.startDate {
                return lhsIsPast ? lhs.snapshot.startDate > rhs.snapshot.startDate
                    : lhs.snapshot.startDate < rhs.snapshot.startDate
            }
            return lhs.id < rhs.id
        }
    }

    private var importedEventKeys: Set<String> {
        Set(planLibrary.plans.compactMap { $0.calendarSource?.eventKey })
    }

    private var changedEvents: [CalendarJourneyCandidate] {
        store.changedSavedEvents(savedPlans: planLibrary.plans)
    }

    var body: some View {
        Group {
            if store.isEnabled {
                enabledCard
            } else if showsIntroduction {
                introductionCard
            }
        }
        .sheet(isPresented: $showsOptions) {
            CalendarImportOptionsView(store: store.importStore, includingEventKeys: importedEventKeys)
        }
        // Changed or cancelled saved events are reviewed in the importer, which shows old and
        // new details side by side and offers removal for cancelled trips.
        .sheet(isPresented: $presentsImporter, onDismiss: {
            guard let pending = pendingImporterReview else { return }
            pendingImporterReview = nil
            intake.review(suggestion: pending.suggestion, isEdited: pending.isEdited)
        }) {
            CalendarImportView { suggestion, isEdited in
                pendingImporterReview = (suggestion, isEdited)
                presentsImporter = false
            }
        }
        .onChange(of: store.state) { _, state in
            if case let .loaded(loaded) = state { planLibrary.adoptStableCalendarKeys(for: loaded) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            guard scenePhase == .active else { return }
            Task { await store.refresh(includingEventKeys: importedEventKeys) }
        }
        .onReceive(NotificationCenter.default.publisher(for: CalendarImportPreferences.didChange)) { _ in
            guard scenePhase == .active else { return }
            Task { await store.refresh(includingEventKeys: importedEventKeys) }
        }
        .task(id: importedEventKeys) {
            if scenePhase == .active { await store.refreshIfStale(includingEventKeys: importedEventKeys) }
        }
        .onChange(of: scenePhase) { old, new in
            if new == .background { store.suspend() }
            if old != .active && new == .active { Task { await store.refresh(includingEventKeys: importedEventKeys) } }
        }
    }

    private var introductionCard: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            Label("Suggestions from Calendar", systemImage: "calendar.badge.plus")
                .font(.headline)
                .foregroundStyle(Color.ttTextPrimary)
            Text("See likely train journeys from your calendars when you open Roundhouse. Events are read on this device, and you choose what to add.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TrainTrackerSpacing.space12) { introductionActions }
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) { introductionActions }
            }
        }
        .padding(LayoutMetrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ticketStubStyle()
    }

    @ViewBuilder
    private var introductionActions: some View {
        Button("Turn On") { Task { await store.enable(includingEventKeys: importedEventKeys) } }
            .buttonStyle(.bordered)
            .accessibilityLabel("Turn on Calendar suggestions")
            .accessibilityIdentifier("calendar-suggestions-enable")
        Button("Not Now") {
            store.dismissIntroduction()
            showsIntroduction = false
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("calendar-suggestions-not-now")
    }

    private var enabledCard: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            HStack(alignment: .firstTextBaseline) {
                Text("From Your Calendar")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ttTextPrimary)
                Spacer(minLength: TrainTrackerSpacing.space8)
                Menu {
                    Button("Calendars and Dates") { showsOptions = true }
                    Button("Refresh") { Task { await store.refresh(includingEventKeys: importedEventKeys) } }
                    Button("Turn Off Suggestions", role: .destructive) { store.disable() }
                        .accessibilityIdentifier("calendar-suggestions-disable")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Calendar suggestion options")
            }
            enabledContent
            Text("\(store.importStore.options.calendarSummary(availableCalendars: store.importStore.calendars)) · \(store.importStore.options.dateRangeSummary)")
                .font(.caption)
                .foregroundStyle(Color.ttTextSecondary)
        }
        .padding(LayoutMetrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ticketStubStyle()
    }

    @ViewBuilder
    private var enabledContent: some View {
        switch store.state {
        case .idle:
            if store.needsAccessRequest {
                Text("Allow Calendar access to see suggestions.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                Button("Allow Calendar Access") { Task { await store.enable(includingEventKeys: importedEventKeys) } }
                    .buttonStyle(.bordered)
            } else {
                Button("Check Calendar") { Task { await store.refresh(includingEventKeys: importedEventKeys) } }
                    .buttonStyle(.bordered)
            }
        case .requestingAccess:
            ProgressView("Requesting Calendar access…")
        case .loading:
            ProgressView("Looking for train journeys…")
        case .loaded, .empty:
            if !changedEvents.isEmpty {
                changedEventsNotice
            }
            if candidates.isEmpty {
                Text("No new train journeys found.")
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
            }
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    CalendarCandidateRow(candidate: candidate, disposition: .newJourney)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: TrainTrackerSpacing.space16) { candidateActions(candidate) }
                        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) { candidateActions(candidate) }
                    }
                }
                if candidate.id != candidates.last?.id {
                    Divider().overlay(Color.ttBorderSubtle)
                }
            }
        case .denied:
            Text("Calendar access is off. Allow full access in Settings to see suggestions.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)
        case .restricted:
            Text("This device restricts Calendar access, so suggestions are unavailable.")
                .font(.subheadline)
                .foregroundStyle(Color.ttTextSecondary)
        case let .error(message):
            Label("Couldn't read Calendar. \(message)", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Color.ttStatusDelayed)
            Button("Try Again") { Task { await store.refresh(includingEventKeys: importedEventKeys) } }
                .buttonStyle(.bordered)
        }
    }

    private var changedEventsNotice: some View {
        let count = changedEvents.count
        return VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            Label(
                count == 1 ? "A saved journey changed in Calendar" : "\(count) saved journeys changed in Calendar",
                systemImage: "calendar.badge.exclamationmark"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.ttTextPrimary)
            Button("Review Changes") { presentsImporter = true }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("calendar-suggestions-review-changes")
        }
    }

    @ViewBuilder
    private func candidateActions(_ candidate: CalendarJourneyCandidate) -> some View {
        Button("Review Journey") { onReview(candidate) }
            .buttonStyle(.bordered)
            .accessibilityLabel("Review journey \(candidate.snapshot.title)")
        Button("Dismiss") { store.dismiss(candidate) }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss suggestion for \(candidate.snapshot.title)")
    }
}
