import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

struct LiveRailSeed {
    struct Station {
        let query: String
        let name: String
        let country: String
        let ticketName: String?
        /// Exact Transitous boarding node when independent feeds publish the same station label.
        let nativeID: String?
        init(_ query: String, _ name: String, _ country: String, ticketName: String? = nil, nativeID: String? = nil) {
            self.query = query; self.name = name; self.country = country; self.ticketName = ticketName
            self.nativeID = nativeID
        }
    }
    let label: String
    let origin: Station
    let destination: Station
    var operatorContains: String? = nil
    var startsNextMorning = true
    var maximumTransfers = 0
}

/// The network and app stores are real. Each case has an isolated ticket vault/defaults suite.
@MainActor
enum LiveImportTrackingFlow {
    private static var nextSeedStart = ContinuousClock.now

    static func run(_ seed: LiveRailSeed, in test: XCTestCase) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_TRAIN_TRACKER_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_TRAIN_TRACKER_TESTS=1 to exercise real rail services")
        }
        // Four place searches and two journey searches per seed stay below the backend's
        // unchanged 30/minute and 12/minute limits, with space for diagnostic traffic.
        let start = max(ContinuousClock.now, nextSeedStart)
        nextSeedStart = start.advanced(by: .seconds(13))
        try await Task.sleep(until: start, clock: .continuous)
        let baseURL = try XCTUnwrap(URL(string: environment["TRAIN_TRACKER_LIVE_BASE_URL"] ?? "http://127.0.0.1:8791"))
        let traffic = LiveRailHTTPRecorder()
        do {
            let result = try await execute(seed, baseURL: baseURL, traffic: traffic)
            attach("Completed flow \(seed.label); XCTest assertions determine the test result.\n\(result)\n\(await traffic.evidence)", seed: seed, to: test)
        } catch {
            attach("FAIL \(seed.label)\n\(error.localizedDescription)\n\(await traffic.evidence)", seed: seed, to: test)
            throw error
        }
    }

    private static func execute(_ seed: LiveRailSeed, baseURL: URL, traffic: LiveRailHTTPRecorder) async throws -> String {
        let client = JourneySearchClient(baseURL: baseURL, client: traffic)
        let snapshots = TripSnapshotBackendClient(baseURL: baseURL, client: traffic)
        let origin = try await station(client, seed: seed.origin)
        let destination = try await station(client, seed: seed.destination)
        let searchTime = searchTime(for: seed, origin: origin)
        let page = try await client.searchJourneys(criteria: JourneySearchCriteria(
            originID: origin.id, destinationID: destination.id, requestedTime: searchTime,
            timeZoneIdentifier: origin.timeZoneIdentifier, arriveBy: false,
            maximumTransfers: seed.maximumTransfers, cursor: nil
        ))
        let candidates = page.options.filter { option in
            let rails = railSegments(option)
            guard !rails.isEmpty, option.transferCount <= seed.maximumTransfers,
                  case .rail? = option.segments.first, case .rail? = option.segments.last,
                  let departure = rails.first?.from.scheduledDeparture, departure >= searchTime,
                  !option.trackingToken.isEmpty,
                  rails.allSatisfy({ $0.isTrackable && $0.tripID != nil && !$0.isCancelled && !$0.from.isCancelled && !$0.to.isCancelled })
            else { return false }
            return seed.operatorContains.map { rails[0].operatorName.localizedCaseInsensitiveContains($0) } ?? true
        }
        let discovered = try XCTUnwrap(candidates.first { option in
            railSegments(option).first?.trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } ?? candidates.first, "No viable \(seed.label) journey: \(page.warnings)")
        let discoveryRails = railSegments(discovered)
        let firstRail = try XCTUnwrap(discoveryRails.first)
        let lastRail = try XCTUnwrap(discoveryRails.last)
        let departure = try XCTUnwrap(firstRail.from.scheduledDeparture)
        let arrival = try XCTUnwrap(lastRail.to.scheduledArrival)
        let number = firstRail.trainNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceLine = number.flatMap { $0.isEmpty ? nil : "Train \($0)" } ?? "Train ticket"
        let printedOrigin = seed.origin.ticketName ?? origin.displayName
        let printedDestination = seed.destination.ticketName ?? destination.displayName
        let directory = try LiveRailPersistenceProof.ticketDirectory()
        let suite = "LiveImportTracking.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var retainedForColdProof = false
        defer {
            if !retainedForColdProof {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let tripFile = LiveRailPersistenceProof.tripFile(in: directory)
        let planFile = LiveRailPersistenceProof.planFile(in: directory)
        let trips = TripLibrary(
            trips: [], backendSnapshots: snapshots, pushCoordinator: LiveImportNoPushCoordinator(),
            archive: TripArchive(defaults: defaults, fileURL: tripFile), automaticRefreshEnabled: false
        )
        let plans = try JourneyPlanLibrary(tripLibrary: trips, archive: JourneyPlanArchive(defaults: defaults, fileURL: planFile))
        let vault = LocalJourneyTicketStore(directory: directory)
        let payload = Data("""
        Train ticket
        \(serviceLine)
        From: \(printedOrigin)
        To: \(printedDestination)
        Departure: \(iso(departure))
        Seat 14A
        """.utf8)
        let imported = try await vault.importPayload(payload, kind: .text, filename: "synthetic-live-ticket.txt")
        XCTAssertTrue(imported.isNew)
        XCTAssertEqual(imported.ticket.suggestion.originGuess, printedOrigin)
        XCTAssertEqual(imported.ticket.suggestion.destinationGuess, printedDestination)
        XCTAssertEqual(imported.ticket.suggestion.trainNumberGuess.map { String($0.uppercased().filter { $0.isLetter || $0.isNumber }) },
                       expectedPrintedNumber(number))
        let parsedDeparture = try XCTUnwrap(imported.ticket.suggestion.departureDate)
        XCTAssertEqual(parsedDeparture.timeIntervalSince1970, departure.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(imported.ticket.details.seat, "14A")
        let intake = JourneyIntakeModel(vault: vault)
        intake.review(ticket: imported.ticket)
        guard case let .review(request) = intake.presentation else { throw LiveFlowFailure("Ticket did not enter review") }
        let review = SmartJourneyReviewStore(
            suggestion: request.suggestion, client: client, planTracker: plans, plans: { plans.plans }
        )
        defer { review.cancelMatching() }
        review.start()
        try await awaitIdle(review, stage: "ticket matching")
        var explicitSelection = false
        if number?.isEmpty != false, review.search.phase == .reviewing {
            review.search.returnToOutboundResults()
        }
        if review.search.phase == .showingOutbound {
            // Equivalent to selecting the discovered itinerary in the app's results screen.
            // Do not repair failed parsing or station lookup by assigning an endpoint here.
            let choice = try XCTUnwrap(review.search.visibleOutboundOptions.first { sameServices($0, discovered) },
                                      "Matching results did not contain the seeded service")
            review.search.selectOutbound(choice)
            explicitSelection = true
        }
        if number?.isEmpty != false {
            XCTAssertTrue(explicitSelection, "An unnumbered ticket must explicitly select its exact discovered service")
        }
        guard review.search.phase == .reviewing else {
            throw LiveFlowFailure("Matching stopped at \(review.stage)/\(review.search.phase); missing \(review.missingFields); route \(String(describing: imported.ticket.suggestion.originGuess)) → \(String(describing: imported.ticket.suggestion.destinationGuess)); \(review.search.importedReviewMessage ?? String(describing: review.search.journeyFailureReason))")
        }
        let selected = try XCTUnwrap(review.search.selectedOutbound)
        let selectedRails = railSegments(selected)
        XCTAssertTrue(sameServices(selected, discovered), "Review must retain the discovered service identities, dates, stops, and scheduled times")
        XCTAssertEqual(review.search.form.origin?.id, origin.id)
        XCTAssertEqual(review.search.form.destination?.id, destination.id)
        XCTAssertTrue(plans.plans.isEmpty)
        review.search.resolveSelection()
        try await awaitIdle(review, stage: "train resolution")
        guard review.search.phase == .reviewing, review.search.canTrackAvailableTrips,
              review.search.resolutionFailures.isEmpty else {
            throw LiveFlowFailure("Resolution stopped at \(review.search.phase): \(review.search.resolutionFailures)")
        }
        let resolved = try XCTUnwrap(review.search.resolvedPlan?.directions.first)
        XCTAssertEqual(resolved.fingerprint, selected.fingerprint)
        XCTAssertEqual(resolved.departure, selected.startTime)
        XCTAssertEqual(resolved.arrival, selected.endTime)
        XCTAssertTrue(review.search.trackResolvedPlan())
        let saved = try XCTUnwrap(plans.plans.first)
        let expectedIDs = uniqueIDs(discoveryRails.compactMap(\.tripID))
        XCTAssertEqual(saved.outbound.childTripIDs, expectedIDs)
        // The signed itinerary carries current start/end predictions; its individual legs
        // retain the ticket's scheduled anchors even when a live train is delayed.
        XCTAssertEqual(saved.outbound.fingerprint, selected.fingerprint)
        XCTAssertEqual(saved.outbound.departure, selected.startTime)
        XCTAssertEqual(saved.outbound.arrival, selected.endTime)
        let savedRails = (saved.outbound.selectedSegments ?? []).filter { $0.kind == .rail }
        XCTAssertEqual(savedRails.count, discoveryRails.count)
        XCTAssertEqual(savedRails.count, selectedRails.count)
        for (savedRail, selectedRail) in zip(savedRails, selectedRails) {
            XCTAssertEqual(savedRail.resolvedTripID, selectedRail.tripID)
            XCTAssertEqual(savedRail.from.id, selectedRail.from.place.id)
            XCTAssertEqual(savedRail.to.id, selectedRail.to.place.id)
            XCTAssertEqual(savedRail.departure, selectedRail.from.scheduledDeparture)
            XCTAssertEqual(savedRail.arrival, selectedRail.to.scheduledArrival)
        }
        XCTAssertEqual(savedRails.first?.departure, departure)
        XCTAssertEqual(savedRails.last?.arrival, arrival)
        XCTAssertEqual(savedRails.first?.from.id, firstRail.from.place.id)
        XCTAssertEqual(savedRails.last?.to.id, lastRail.to.place.id)
        XCTAssertEqual(savedRails.first?.from.countryCode, seed.origin.country)
        XCTAssertEqual(savedRails.last?.to.countryCode, seed.destination.country)
        intake.completeReview(request, plan: saved, created: true, navigation: AppNavigationModel())
        XCTAssertNil(intake.errorMessage)

        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let archive = TripArchive(defaults: reloadedDefaults, fileURL: tripFile)
        let reloadedTrips = TripLibrary(
            backendSnapshots: snapshots, pushCoordinator: LiveImportNoPushCoordinator(),
            archive: archive, automaticRefreshEnabled: true
        )
        let planArchive = JourneyPlanArchive(defaults: reloadedDefaults, fileURL: planFile)
        let reloadedPlans = try JourneyPlanLibrary(tripLibrary: reloadedTrips, archive: planArchive)
        let reloadedVault = LocalJourneyTicketStore(directory: directory)
        XCTAssertFalse(reloadedTrips.tripArchiveRecoveryRequired)
        XCTAssertTrue(reloadedPlans.recoveryIssues.isEmpty)
        XCTAssertEqual(reloadedPlans.plans, [saved])
        XCTAssertEqual(reloadedTrips.trips.map(\.id), expectedIDs)
        XCTAssertEqual(reloadedVault.tickets(forPlan: saved.id).map(\.id), [imported.ticket.id])
        XCTAssertEqual(try reloadedVault.payload(id: imported.ticket.id), payload)
        var refreshedEvidence: [String] = []
        for tripID in expectedIDs {
            XCTAssertNil(reloadedTrips.lastSuccessfulCheck(for: tripID))
            let count = await traffic.snapshotResponses.count
            let started = Date.now
            await reloadedTrips.refreshTrackedTrip(id: tripID)
            let responses = await traffic.snapshotResponses
            XCTAssertGreaterThan(responses.count, count, "Refresh must request an actual backend snapshot")
            XCTAssertEqual(responses.last?.status, 200, "Direct-provider fallback alone cannot pass this test")
            XCTAssertEqual(responses.last?.tripID, tripID.rawValue)
            XCTAssertNil(reloadedTrips.refreshError)
            XCTAssertFalse(reloadedTrips.lastRefreshFailed(for: tripID))
            let checked = try XCTUnwrap(reloadedTrips.lastSuccessfulCheck(for: tripID))
            let refreshed = try XCTUnwrap(reloadedTrips.trip(id: tripID))
            if refreshed.source == "srbijavoz" {
                // A current timetable or retained schedule keeps the upstream
                // observation time; requesting it again is not new live evidence.
                let observed = try XCTUnwrap(refreshed.sourceFetchedAt)
                XCTAssertEqual(checked, observed)
                XCTAssertLessThanOrEqual(observed, Date.now)
                XCTAssertFalse(refreshed.capabilities.hasRealtimeDelays)
            } else {
                XCTAssertGreaterThanOrEqual(checked, started)
            }
            let rail = try XCTUnwrap(discoveryRails.first { $0.tripID == tripID })
            XCTAssertEqual(refreshed.serviceDate, rail.serviceDate)
            XCTAssertGreaterThanOrEqual(refreshed.stopTimes.count, 2)
            for segment in savedRails where segment.resolvedTripID == tripID {
                try checkPassengerBounds(trip: refreshed, segment: segment)
            }
            let persistedCheck = try XCTUnwrap(archive.loadLastChecks()[tripID])
            // The archive stores a Double epoch; Date's reference-epoch conversion can
            // round the last fractional bit even when the instant is faithfully retained.
            XCTAssertEqual(persistedCheck.timeIntervalSince1970, checked.timeIntervalSince1970, accuracy: 0.000001)
            refreshedEvidence.append("\(tripID.rawValue): \(refreshed.stopTimes.count) stops, checked \(iso(checked))")
        }
        XCTAssertEqual(archive.load(), reloadedTrips.trips)
        XCTAssertEqual(reloadedVault.ticket(id: imported.ticket.id)?.linkedPlanIDs, [saved.id])
        let coldProof = try LiveRailPersistenceProof.record(tripArchive: archive, planArchive: planArchive, suite: suite, seed: seed.label,
            vaultDirectory: directory, ticketID: imported.ticket.id, planID: saved.id, payload: payload)
        retainedForColdProof = coldProof != nil
        let services = discoveryRails.map {
            "\($0.operatorName) \($0.product) number=\($0.trainNumber ?? "absent") serviceDay=\(iso($0.serviceDate)) providerIsRealtime=\($0.isRealtime)"
        }.joined(separator: "\n")
        return """
        Real backend: \(baseURL.absoluteString)
        \(services)
        Ticket departure: \(iso(departure)); explicit itinerary selection: \(explicitSelection)
        Scheduled passenger times: \(iso(departure)) → \(iso(arrival))
        Selected itinerary times: \(iso(selected.startTime)) → \(iso(selected.endTime))
        Saved plan: \(saved.id); ticket: \(imported.ticket.id)
        Cold-app persistence proof: \(coldProof ?? "not requested")
        Passenger bounds: \(firstRail.from.place.displayName) → \(lastRail.to.place.displayName)
        \(refreshedEvidence.joined(separator: "\n"))
        """
    }

    private static func station(_ client: JourneySearchClient, seed: LiveRailSeed.Station) async throws -> RailPlace {
        let places = try await client.searchPlaces(query: seed.query, limit: 20)
        return try XCTUnwrap(LiveRailSeedStationMatcher.uniqueMatch(in: places, seed: seed),
                            "Expected exactly one live station \(seed.name) in \(seed.country); returned \(places.map(\.displayName))")
    }

    private static func searchTime(for seed: LiveRailSeed, origin: RailPlace) -> Date {
        let earliest = Date.now.addingTimeInterval(30 * 60)
        guard seed.startsNextMorning else { return earliest }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: origin.timeZoneIdentifier) ?? .gmt
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: earliest) ?? earliest
        return morning >= earliest ? morning : calendar.date(byAdding: .day, value: 1, to: morning) ?? earliest
    }

    private static func checkPassengerBounds(trip: TrainTrip, segment: JourneyPlanSegment) throws {
        let passenger = RailJourneyProgress(trip: trip, referenceDate: .now, boardingPlace: segment.from, alightingPlace: segment.to)
        XCTAssertNotEqual(passenger.phase, .unavailable)
        let boarding = try XCTUnwrap(passenger.stops.first)
        let alighting = try XCTUnwrap(passenger.stops.last)
        XCTAssertNotEqual(boarding.station.id, alighting.station.id)
        XCTAssertEqual(boarding.scheduledDeparture, segment.departure)
        XCTAssertEqual(alighting.scheduledArrival, segment.arrival)
        XCTAssertEqual(boarding.station.location.latitude, segment.from.location.latitude, accuracy: 0.001)
        XCTAssertEqual(boarding.station.location.longitude, segment.from.location.longitude, accuracy: 0.001)
        XCTAssertEqual(alighting.station.location.latitude, segment.to.location.latitude, accuracy: 0.001)
        XCTAssertEqual(alighting.station.location.longitude, segment.to.location.longitude, accuracy: 0.001)
    }

    private static func railSegments(_ option: JourneyOption) -> [RailJourneySegment] {
        option.segments.compactMap { if case let .rail(rail) = $0 { rail } else { nil } }
    }

    private static func expectedPrintedNumber(_ providerNumber: String?) -> String? {
        guard let number = providerNumber?.uppercased(), !number.isEmpty else { return nil }
        // Product letters are part of matching evidence; whitespace formatting is not.
        return String(number.filter { $0.isLetter || $0.isNumber })
    }

    private static func sameServices(_ lhs: JourneyOption, _ rhs: JourneyOption) -> Bool {
        let left = railSegments(lhs), right = railSegments(rhs)
        return !left.isEmpty && left.count == right.count
            && left.compactMap(\.tripID) == right.compactMap(\.tripID)
            && left.map(\.serviceDate) == right.map(\.serviceDate)
            && left.map(\.from.place.id) == right.map(\.from.place.id)
            && left.map(\.to.place.id) == right.map(\.to.place.id)
            && left.map(\.from.scheduledDeparture) == right.map(\.from.scheduledDeparture)
            && left.map(\.to.scheduledArrival) == right.map(\.to.scheduledArrival)
    }

    private static func uniqueIDs(_ values: [RailIdentifier]) -> [RailIdentifier] {
        var seen: Set<RailIdentifier> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func awaitIdle(_ review: SmartJourneyReviewStore, stage: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while review.isPreparingSearch || review.search.isJourneyTaskActive {
            guard ContinuousClock.now < deadline else { throw LiveFlowFailure("Timed out during \(stage): \(review.search.phase)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func attach(_ text: String, seed: LiveRailSeed, to test: XCTestCase) {
        let evidence = XCTAttachment(string: text)
        evidence.name = "Live flow \(seed.label)"
        evidence.lifetime = .keepAlways
        test.add(evidence)
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

struct LiveFlowFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
private final class LiveImportNoPushCoordinator: PushCoordinating {
    var deliveryWarningHandler: ((PushDeliveryWarningEvent) -> Void)?
    func connect() {}
    func watch(_ trip: TrainTrip) {}
    func unwatch(_ trip: TrainTrip) {}
    func retryDelivery() {}
}
