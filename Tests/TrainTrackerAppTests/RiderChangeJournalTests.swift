import XCTest
import TrainTrackerCore
@testable import TrainTracker

@MainActor final class RiderChangeJournalTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_795_019_400)

    func testAmtrakLosesPositionKeepsLastReportAndEstimatesAcrossFailureRestartAndRecovery() async throws {
        let scenario = TripUpdatesQA.amtrak
        let original = scenario.snapshot(.baseline, now: time)
        let gap = scenario.snapshot(.interruption, now: time)
        let resumed = scenario.snapshot(.recovery, now: time)
        let source = ChangingSource(original)
        let suite = "RiderChangeJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = TripArchive(defaults: defaults)
        let now = time
        func library() -> TripLibrary {
            TripLibrary(backendSnapshots: source, pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: archive, now: { now })
        }
        let initial = library()
        try initial.storeTrackedTrip(original)
        await initial.refreshTrackedTrip(id: original.id)
        XCTAssertTrue(initial.changeJournal(for: original.id).batches.isEmpty)
        await source.set(gap)
        await initial.refreshTrackedTrip(id: original.id)
        let saved = initial.changeJournal(for: original.id)
        XCTAssertEqual(saved.lastPositionReport, original.positions.first?.asOf)
        XCTAssertEqual(saved.batches.count, 1)
        let reopened = library()
        XCTAssertEqual(reopened.changeJournal(for: gap.id), saved)
        let presentation = TripUpdatePresentation(experience: experience(gap), journal: saved)
        XCTAssertTrue(try XCTUnwrap(presentation.headline).title.contains("Last position reported"))
        XCTAssertTrue(try XCTUnwrap(presentation.headline).detail.contains("Estimated arrival at New York Penn"))
        XCTAssertTrue(presentation.changes.contains { $0.title == "Track changed from 4 to 7" })
        await source.set(nil)
        await reopened.refreshTrackedTrip(id: gap.id)
        XCTAssertTrue(reopened.lastRefreshFailed(for: gap.id))
        XCTAssertEqual(reopened.changeJournal(for: gap.id), saved)
        await source.set(gap)
        await reopened.refreshTrackedTrip(id: gap.id)
        XCTAssertEqual(reopened.changeJournal(for: gap.id), saved, "Unchanged snapshots cannot refresh the GPS clock or duplicate the delay")
        await source.set(resumed)
        await reopened.refreshTrackedTrip(id: gap.id)
        let recovered = reopened.changeJournal(for: gap.id)
        XCTAssertEqual(recovered.lastPositionReport, resumed.positions.first?.asOf)
        XCTAssertEqual(recovered.batches.first?.changes.first?.fact, .positionResumed)
        XCTAssertNil(TripUpdatePresentation(experience: experience(resumed), journal: recovered).positionNote)
        XCTAssertEqual(library().changeJournal(for: gap.id), recovered)
        XCTAssertTrue(reopened.removeTrip(id: gap.id))
        let fresh = library()
        try fresh.storeTrackedTrip(gap)
        XCTAssertTrue(fresh.changeJournal(for: gap.id).batches.isEmpty)
        XCTAssertNil(fresh.changeJournal(for: gap.id).lastPositionReport)
    }

    func testSpainUpstreamGPSOverridesPassedTimetableAndAdvancesOnlyWithNewEvidence() throws {
        let original = TripUpdatesQA.spain.snapshot(.baseline, now: time)
        let delayed = TripUpdatesQA.spain.snapshot(.interruption, now: time)
        let recovered = TripUpdatesQA.spain.snapshot(.recovery, now: time)
        let intermediate = delayed.stopTimes[1]
        XCTAssertLessThan(try XCTUnwrap(intermediate.scheduledArrival), time)
        XCTAssertTrue(intermediate.isPassed, "The old supplier even marked this call passed by the timetable")
        let late = experience(delayed)
        XCTAssertEqual(late.progress.evidence.basis, .vehiclePosition)
        XCTAssertEqual(late.progress.focusStop?.id, intermediate.id)
        XCTAssertFalse(late.progress.evidence.confirmedPassedStopIDs.contains(intermediate.id))
        XCTAssertFalse(late.progress.evidence.isArrivalConfirmed)
        var journal = TripChangeJournal()
        journal.observe(previous: original, current: delayed, hadConfirmedCheck: true, at: time)
        let notes = TripUpdatePresentation(experience: late, journal: journal)
        XCTAssertEqual(notes.positionNote?.title, "Arrival at Zaragoza-Delicias unconfirmed")
        XCTAssertTrue(notes.changes.contains { $0.title == "Arrival estimated 25 min late" })
        let recoveredExperience = experience(recovered)
        XCTAssertTrue(recoveredExperience.progress.evidence.confirmedPassedStopIDs.contains(intermediate.id))
        XCTAssertEqual(recoveredExperience.progress.focusStop?.station.displayName, "Barcelona Sants")
        XCTAssertNil(TripUpdatePresentation(experience: recoveredExperience, journal: journal).positionNote)
    }

    func testOnlyBookedCallsAppearAndAnInvalidLegCannotLeakAnotherStationsChanges() throws {
        let base = TripUpdatesQA.amtrak.snapshot(.baseline, now: time)
        let gap = TripUpdatesQA.amtrak.snapshot(.interruption, now: time)
        var journal = TripChangeJournal()
        journal.observe(previous: base, current: gap, hadConfirmedCheck: true, at: time)
        func endpoint(_ stop: StopTime) -> RailPlace {
            RailPlace(id: stop.station.id, kind: .station, displayName: stop.station.displayName, context: "", countryCode: "US",
                      timeZoneIdentifier: "America/New_York", location: stop.station.location, eligibleModes: ["rail"], attributions: [])
        }
        let ends = gap.stopTimes.map(endpoint)
        let leg = JourneyPlanSegment(id: "passenger", kind: .rail, from: ends[0], to: ends[1])
        let notes = TripUpdatePresentation(experience: experience(gap, segment: leg), journal: journal)
        XCTAssertTrue(notes.changes.contains { $0.detail.contains("Baltimore Penn") })
        XCTAssertFalse(notes.changes.contains { $0.detail.contains("New York") })
        XCTAssertTrue(try XCTUnwrap(notes.positionNote).detail.contains("Timetable arrival at Baltimore Penn"))
        let invalid = JourneyPlanSegment(id: "reversed", kind: .rail, from: ends[2], to: ends[0])
        XCTAssertNil(TripUpdatePresentation(experience: experience(gap, segment: invalid), journal: journal).headline)
    }

    func testNoNewEventOnInitialCheckOrWhenOpeningAfterANormalGapBetweenChecks() {
        let base = TripUpdatesQA.amtrak.snapshot(.baseline, now: time)
        let latest = TripUpdatesQA.amtrak.snapshot(.recovery, now: time)
        var journal = TripChangeJournal()
        journal.observe(previous: base, current: base, hadConfirmedCheck: false, at: time.addingTimeInterval(-14 * 60))
        XCTAssertTrue(journal.batches.isEmpty)
        journal.observe(previous: base, current: latest, hadConfirmedCheck: true, at: time)
        XCTAssertFalse(journal.batches.flatMap(\.changes).contains { $0.fact == .positionResumed })
    }

    func testReplayedSnapshotsAndAnotherServiceDayCannotAnnounceOldChanges() {
        let baseline = TripUpdatesQA.spain.snapshot(.baseline, now: time)
        let next = TripUpdatesQA.spain.snapshot(.interruption, now: time)
        var journal = TripChangeJournal()
        journal.observe(previous: baseline, current: next, hadConfirmedCheck: true, at: time)
        let count = journal.batches.count
        journal.observe(previous: next, current: baseline, hadConfirmedCheck: true, at: time.addingTimeInterval(30))
        journal.observe(previous: baseline, current: next, hadConfirmedCheck: true, at: time.addingTimeInterval(60))
        XCTAssertEqual(journal.batches.count, count)
        let tomorrow = TripUpdatesQA.spain.snapshot(.baseline, now: time.addingTimeInterval(86400))
        journal.observe(previous: next, current: tomorrow, hadConfirmedCheck: true, at: time.addingTimeInterval(86400))
        XCTAssertTrue(journal.batches.isEmpty)
    }

    func testSpainTimetableWithoutTrainPositionCannotConfirmTheBookedArrivalOrStamp() throws {
        let trip = TripUpdatesQA.spain.snapshot(.timetableOnly, now: time)
        let stop = trip.stopTimes[1]
        XCTAssertTrue(trip.positions.isEmpty)
        XCTAssertTrue(stop.isPassed)
        XCTAssertLessThan(try XCTUnwrap(stop.scheduledArrival), time)
        XCTAssertNil(stop.arrivalObservedAt)
        XCTAssertNil(stop.passageObservedAt)
        let full = experience(trip)
        XCTAssertEqual(full.focusLabel, "Next scheduled stop")
        XCTAssertEqual(full.focusName, "Barcelona Sants")
        XCTAssertEqual(JourneyTrackingHeaderPresentation(experience: full).statusText, "Arrival at Zaragoza-Delicias unconfirmed")
        let recovered = experience(TripUpdatesQA.spain.snapshot(.recovery, now: time))
        XCTAssertNil(recovered.unreportedScheduledStopText)
        XCTAssertEqual(full.progress.evidence.basis, .unconfirmed)
        XCTAssertTrue(full.progress.evidence.confirmedPassedStopIDs.isEmpty)
        XCTAssertFalse(ArrivalEvidence.hasReached(stop, progress: full.progress))
        func place(_ station: Station) -> RailPlace {
            RailPlace(id: station.id, kind: .station, displayName: station.displayName, context: "", countryCode: "ES",
                      timeZoneIdentifier: "Europe/Madrid", location: station.location, eligibleModes: ["rail"], attributions: [])
        }
        let leg = JourneyPlanSegment(id: "madrid-zaragoza", kind: .rail, from: place(trip.stopTimes[0].station), to: place(stop.station))
        let booked = experience(trip, segment: leg)
        let card = ActiveTripCardPresentation(trip: trip, referenceDate: time, selectedSegment: leg)
        XCTAssertEqual(booked.phaseTitle, "Arrival unconfirmed")
        XCTAssertEqual(card.nextStopValue, "Arrival unconfirmed")
        XCTAssertTrue(ArrivalEvidence.timetableElapsedUnconfirmed(booked.progress))
        XCTAssertFalse(ArrivalEvidence.arrivalIsConfirmed(progress: booked.progress))
        let stub = try XCTUnwrap(TravelLogEntry(trip: trip, stops: booked.progress.stops,
                                               arrivalConfirmed: ArrivalEvidence.arrivalIsConfirmed(progress: booked.progress)))
        XCTAssertFalse(stub.isArrivalConfirmed)
        var journal = TripChangeJournal()
        journal.observe(previous: trip, current: trip, hadConfirmedCheck: true, at: time)
        XCTAssertNil(TripUpdatePresentation(experience: booked, journal: journal).headline)
    }

    func testOnlyExactDeliveredAlertIsKeptWithItsDeliveryDateAndDeduplicatesTheNextPoll() throws {
        let base = TripUpdatesQA.amtrak.snapshot(.baseline, now: time)
        let gap = TripUpdatesQA.amtrak.snapshot(.interruption, now: time)
        let delivered = time.addingTimeInterval(-20)
        let day = String(ISO8601DateFormatter().string(from: base.serviceDate).prefix(10))
        let payload: [String: String] = ["tripID": base.id.rawValue, "eventID": "receipt-1", "eventServiceDate": day,
                                        "eventKind": "platform-change", "eventOldValue": "4", "eventNewValue": "7",
                                        "stopID": base.stopTimes[1].station.id.rawValue]
        func receipt(_ changes: [String: String] = [:], at date: Date? = nil) throws -> TripDeliveredAlert {
            try XCTUnwrap(TripDeliveredAlert(userInfo: payload.merging(changes) { _, new in new }, date: date ?? delivered))
        }
        XCTAssertNil(TripDeliveredAlert(userInfo: payload.filter { $0.key != "eventServiceDate" }, date: delivered))
        let alert = try receipt()
        var journal = TripChangeJournal()
        XCTAssertFalse(journal.accept(try receipt(["eventServiceDate": "2020-01-01"]), for: gap, at: time))
        XCTAssertFalse(journal.accept(try receipt(["tripID": "other:run"]), for: gap, at: time))
        XCTAssertFalse(journal.accept(try receipt(["stopID": "no-such-stop"]), for: gap, at: time))
        XCTAssertFalse(journal.accept(try receipt(at: time.addingTimeInterval(60)), for: gap, at: time))
        XCTAssertTrue(journal.accept(alert, for: gap, at: time))
        XCTAssertFalse(journal.accept(alert, for: gap, at: time))
        journal.observe(previous: base, current: gap, hadConfirmedCheck: true, at: time, since: time.addingTimeInterval(-120))
        let lines = TripUpdatePresentation(experience: experience(gap), journal: journal).changes
        let tracks = lines.filter { $0.title == "Track changed from 4 to 7" }
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(try XCTUnwrap(tracks.first).detail.contains("Alert delivered"))
        XCTAssertTrue(lines.contains { $0.title == "Arrival estimated 12 min late" })
        XCTAssertEqual(journal.timeline.first { $0.receiptID == alert.id }?.seenAt, delivered)

        let suite = "RiderChangeJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = TripArchive(defaults: defaults)
        let now = time
        func open() -> TripLibrary {
            TripLibrary(backendSnapshots: ChangingSource(gap), pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: archive, now: { now })
        }
        let library = open()
        try library.storeTrackedTrip(base)
        try library.keepDeliveredAlerts([alert, alert])
        let reopened = open()
        XCTAssertNil(reopened.lastSuccessfulCheck(for: base.id))
        try reopened.keepDeliveredAlerts([alert])
        XCTAssertEqual(reopened.changeJournal(for: base.id).timeline.count, 1)
        XCTAssertEqual(reopened.changeJournal(for: base.id).timeline.first?.seenAt, delivered)
    }

    private func experience(_ trip: TrainTrip, segment: JourneyPlanSegment? = nil) -> JourneyExperiencePresentation {
        JourneyExperiencePresentation(trip: trip, timeZones: TripDetailTimeZoneContext(trip: trip), referenceDate: time,
                                      lastSuccessfulCheck: time, selectedSegment: segment)
    }
}

private actor ChangingSource: TripDataProviding {
    private var next: TrainTrip?
    init(_ next: TrainTrip) { self.next = next }
    func set(_ trip: TrainTrip?) { next = trip }
    func searchStations(query: String, source: RailSource) async throws -> [Station] { [] }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection, source: RailSource?) async throws -> [StopTimeSummary] { [] }
    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { try value() }
    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip { try value() }
    private func value() throws -> TrainTrip {
        guard let next else { throw URLError(.notConnectedToInternet) }
        return next
    }
}
