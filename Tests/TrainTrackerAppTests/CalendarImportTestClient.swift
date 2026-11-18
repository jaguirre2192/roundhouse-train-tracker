import EventKit
import Foundation
@testable import TrainTracker

/// Only this synchronous authorization cell crosses isolation; all mutable scripted
/// operations and continuations stay on the actor below.
private final class CalendarImportTestAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var status: EKAuthorizationStatus

    init(_ status: EKAuthorizationStatus) { self.status = status }

    func read() -> EKAuthorizationStatus { lock.withLock { status } }
    func set(_ status: EKAuthorizationStatus) { lock.withLock { self.status = status } }
}

actor CalendarImportTestClient: CalendarImportClientProtocol {
    private nonisolated let authorization: CalendarImportTestAuthorization
    private let suspendsAccess: Bool
    private let suspendsFetch: Bool
    private let suspendsCalendars: Bool
    private let accessResult: Result<Bool, Error>
    private let authorizationAfterRequest: EKAuthorizationStatus
    private let fetchResult: Result<[CalendarJourneyCandidate], Error>
    private let snapshots: [CalendarEventSnapshot]?
    private let calendarResult: Result<[CalendarDescriptor], Error>
    private var accessContinuation: CheckedContinuation<Bool, Error>?
    private var fetchContinuations: [Int: CheckedContinuation<[CalendarJourneyCandidate], Error>] = [:]
    private var calendarContinuations: [Int: CheckedContinuation<[CalendarDescriptor], Error>] = [:]
    private var requestsCancelled = false
    private(set) var accessRequestCount = 0
    private(set) var fetchedWindows: [DateInterval] = []
    private(set) var includedEventKeys: [Set<String>] = []
    private(set) var selectedCalendarIDs: [Set<String>?] = []
    private(set) var calendarRequestCount = 0

    nonisolated var authorizationStatus: EKAuthorizationStatus { authorization.read() }

    init(
        status: EKAuthorizationStatus = .fullAccess,
        accessResult: Result<Bool, Error> = .success(true),
        authorizationAfterRequest: EKAuthorizationStatus = .fullAccess,
        fetchResult: Result<[CalendarJourneyCandidate], Error> = .success([]),
        snapshots: [CalendarEventSnapshot]? = nil,
        calendarResult: Result<[CalendarDescriptor], Error> = .success([]),
        suspendsAccess: Bool = false,
        suspendsFetch: Bool = false,
        suspendsCalendars: Bool = false
    ) {
        authorization = CalendarImportTestAuthorization(status)
        self.accessResult = accessResult
        self.authorizationAfterRequest = authorizationAfterRequest
        self.fetchResult = fetchResult
        self.snapshots = snapshots
        self.calendarResult = calendarResult
        self.suspendsAccess = suspendsAccess
        self.suspendsFetch = suspendsFetch
        self.suspendsCalendars = suspendsCalendars
    }

    nonisolated func setAuthorization(_ status: EKAuthorizationStatus) {
        authorization.set(status)
    }

    func requestAccess() async throws -> Bool {
        try checkRequestsAreActive()
        accessRequestCount += 1
        if suspendsAccess {
            return try await withCheckedThrowingContinuation { accessContinuation = $0 }
        }
        authorization.set(authorizationAfterRequest)
        return try accessResult.get()
    }

    func fetchCalendars() async throws -> [CalendarDescriptor] {
        try checkRequestsAreActive()
        let index = calendarRequestCount
        calendarRequestCount += 1
        if suspendsCalendars {
            return try await withCheckedThrowingContinuation { calendarContinuations[index] = $0 }
        }
        return try calendarResult.get()
    }

    func fetchCandidates(
        window: DateInterval, includingEventKeys: Set<String>, selectedCalendarIDs: Set<String>?
    ) async throws -> [CalendarJourneyCandidate] {
        try checkRequestsAreActive()
        let index = fetchedWindows.count
        fetchedWindows.append(window)
        includedEventKeys.append(includingEventKeys)
        self.selectedCalendarIDs.append(selectedCalendarIDs)
        if suspendsFetch {
            // Deliberately ignore cancellation to model callbacks that arrive after reset.
            return try await withCheckedThrowingContinuation { fetchContinuations[index] = $0 }
        }
        if let snapshots {
            return snapshots.compactMap { CalendarImportClient.candidate(for: $0, includingEventKeys: includingEventKeys) }
        }
        return try fetchResult.get()
    }

    func resumeAccess(status: EKAuthorizationStatus, result: Result<Bool, Error>) {
        authorization.set(status)
        accessContinuation?.resume(with: result)
        accessContinuation = nil
    }

    func resumeFetch(_ index: Int = 0, result: Result<[CalendarJourneyCandidate], Error>) {
        fetchContinuations.removeValue(forKey: index)?.resume(with: result)
    }

    func resumeCalendars(_ index: Int = 0, result: Result<[CalendarDescriptor], Error>) {
        calendarContinuations.removeValue(forKey: index)?.resume(with: result)
    }

    func waitForCalendarCount(_ count: Int) async -> Bool {
        await waitUntil { calendarRequestCount >= count }
    }

    func waitForAccessRequest() async -> Bool {
        await waitUntil { accessRequestCount > 0 }
    }

    func waitForFetchCount(_ count: Int) async -> Bool {
        await waitUntil { fetchedWindows.count >= count }
    }

    /// End a failed test without leaving its deliberately cancellation-insensitive callbacks suspended.
    func cancelPendingRequests() {
        requestsCancelled = true
        accessContinuation?.resume(throwing: CancellationError())
        accessContinuation = nil
        fetchContinuations.values.forEach { $0.resume(throwing: CancellationError()) }
        fetchContinuations.removeAll()
        calendarContinuations.values.forEach { $0.resume(throwing: CancellationError()) }
        calendarContinuations.removeAll()
    }

    private func checkRequestsAreActive() throws {
        if requestsCancelled { throw CancellationError() }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            // Yield counts do not give MainActor's nested import tasks time to start.
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return true
    }
}
