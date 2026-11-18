import EventKit
import Foundation
import Observation

@MainActor
@Observable
final class CalendarImportStore {
    enum State: Equatable {
        case idle
        case requestingAccess
        case loading
        case loaded([CalendarJourneyCandidate])
        case empty
        case denied
        case restricted
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var calendars: [CalendarDescriptor] = []
    private(set) var options: CalendarImportOptions

    private let client: any CalendarImportClientProtocol
    private let preferences: CalendarImportPreferences
    private let windowOverride: (@Sendable () -> DateInterval)?
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(
        client: any CalendarImportClientProtocol = CalendarImportClient(),
        preferences: CalendarImportPreferences = CalendarImportPreferences(),
        window: (@Sendable () -> DateInterval)? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        calendar: @escaping @Sendable () -> Calendar = { .current }
    ) {
        self.client = client
        self.preferences = preferences
        self.windowOverride = window
        self.now = now
        self.calendar = calendar
        options = preferences.load()
    }

    nonisolated static func defaultWindow(
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -14, to: referenceDate) ?? referenceDate
        let end = calendar.date(byAdding: .day, value: 120, to: referenceDate) ?? referenceDate
        return DateInterval(start: start, end: end)
    }

    /// Call only in response to opening import or explicitly retrying its access request.
    func beginImport(includingEventKeys: Set<String> = []) async {
        await runImport(requestingAccess: true, includingEventKeys: includingEventKeys)
    }

    /// Recheck Settings changes and calendar edits without triggering a permission prompt.
    func refresh(includingEventKeys: Set<String> = []) async {
        // Returning from the system permission sheet can also activate the scene. Let
        // the explicit request finish instead of canceling it with a passive refresh.
        guard state != .requestingAccess else { return }
        await runImport(requestingAccess: false, includingEventKeys: includingEventKeys)
    }

    /// Validate and persist one confirmed draft, then reload without requesting access.
    func updateOptions(_ options: CalendarImportOptions, includingEventKeys: Set<String> = []) async throws {
        _ = try options.dateInterval(referenceDate: now(), calendar: calendar())
        try preferences.save(options)
        self.options = options
        await refresh(includingEventKeys: includingEventKeys)
    }

    func reset() {
        operation?.cancel()
        operation = nil
        operationID = nil
        calendars = []
        state = .idle
    }

    private func runImport(requestingAccess: Bool, includingEventKeys: Set<String>) async {
        guard !Task.isCancelled else { return }
        operation?.cancel()
        let id = UUID()
        operationID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performImport(requestingAccess: requestingAccess, includingEventKeys: includingEventKeys, id: id)
        }
        operation = task

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                self?.cancelOperation(id: id)
            }
        }

        if Task.isCancelled { cancelOperation(id: id) }
        if operationID == id {
            operation = nil
            operationID = nil
        }
    }

    private func performImport(requestingAccess: Bool, includingEventKeys: Set<String>, id: UUID) async {
        guard isCurrent(id) else { return }
        if client.authorizationStatus != .fullAccess { calendars = [] }
        do {
            switch client.authorizationStatus {
            case .fullAccess:
                break
            case .notDetermined where requestingAccess, .writeOnly where requestingAccess:
                state = .requestingAccess
                let granted = try await client.requestAccess()
                guard isCurrent(id) else { return }
                guard granted else {
                    state = client.authorizationStatus == .restricted ? .restricted : .denied
                    return
                }
            case .notDetermined:
                state = .idle
                return
            case .restricted:
                state = .restricted
                return
            default:
                state = .denied
                return
            }

            guard applyCurrentAuthorization() else { return }
            state = .loading
            let availableCalendars = try await client.fetchCalendars()
            guard isCurrent(id), applyCurrentAuthorization() else { return }
            calendars = availableCalendars
            // The importer and the My Trips suggestions each own a store; reading the saved
            // options on every load keeps a change made in one visible in the other.
            if preferences.isPersistent { options = preferences.load() }
            let window = try windowOverride?() ?? options.dateInterval(referenceDate: now(), calendar: calendar())
            let candidates = try await client.fetchCandidates(
                window: window,
                includingEventKeys: includingEventKeys,
                selectedCalendarIDs: options.selectedCalendarIDs
            )
            guard isCurrent(id), applyCurrentAuthorization() else { return }
            state = candidates.isEmpty ? .empty : .loaded(candidates)
        } catch {
            guard isCurrent(id) else { return }
            if error is CancellationError {
                state = .idle
            } else if let clientError = error as? CalendarImportClient.ClientError {
                calendars = []
                state = clientError == .accessRestricted ? .restricted : .denied
            } else if client.authorizationStatus == .restricted {
                calendars = []
                state = .restricted
            } else if [.denied, .writeOnly].contains(client.authorizationStatus) {
                calendars = []
                state = .denied
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func applyCurrentAuthorization() -> Bool {
        switch client.authorizationStatus {
        case .fullAccess:
            return true
        case .restricted:
            calendars = []
            state = .restricted
        default:
            calendars = []
            state = .denied
        }
        return false
    }

    private func isCurrent(_ id: UUID) -> Bool {
        operationID == id && !Task.isCancelled
    }

    private func cancelOperation(id: UUID) {
        guard operationID == id else { return }
        reset()
    }
}
