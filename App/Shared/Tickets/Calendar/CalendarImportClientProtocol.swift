import EventKit
import Foundation

/// Reading authorization never prompts. Only an explicit import action requests access.
protocol CalendarImportClientProtocol: Sendable {
    nonisolated var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    func fetchCalendars() async throws -> [CalendarDescriptor]
    func fetchCandidates(
        window: DateInterval,
        includingEventKeys: Set<String>,
        selectedCalendarIDs: Set<String>?
    ) async throws -> [CalendarJourneyCandidate]
}

extension CalendarImportClientProtocol {
    func fetchCandidates(
        window: DateInterval,
        includingEventKeys: Set<String> = []
    ) async throws -> [CalendarJourneyCandidate] {
        try await fetchCandidates(window: window, includingEventKeys: includingEventKeys, selectedCalendarIDs: nil)
    }
}
