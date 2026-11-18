import PDFKit
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class PlatformBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func experience(_ trip: TrainTrip, at date: Date? = nil, check: Date? = nil,
                            failed: Bool = false, segment: JourneyPlanSegment? = nil) -> JourneyExperiencePresentation {
        let reference = date ?? now
        return JourneyExperiencePresentation(trip: trip, timeZones: TripDetailTimeZoneContext(trip: trip),
                                            referenceDate: reference, lastSuccessfulCheck: check ?? reference,
                                            refreshFailed: failed, selectedSegment: segment)
    }

    func testReportedAssignmentOnSelectedBoardingCallAndNativeSign() throws {
        let trip = PlatformBoardQA.trip(at: now)
        let board = try XCTUnwrap(PlatformBoardPresentation(experience: experience(trip)))
        XCTAssertEqual(board.number, "7")
        XCTAssertEqual(board.previous, "4")
        XCTAssertEqual(board.station, "Madrid Puerta de Atocha")
        XCTAssertEqual(board.stationTerm, "Vía")
        let segment = JourneyPlanSegment(id: "second-leg", kind: .rail, from: PlatformBoardQA.place(trip.stopTimes[1].station),
                                         to: PlatformBoardQA.place(trip.stopTimes[2].station), resolvedTripID: trip.id)
        let intermediate = try XCTUnwrap(PlatformBoardPresentation(experience: experience(trip, segment: segment)))
        XCTAssertEqual(intermediate.station, "Zaragoza-Delicias")
        XCTAssertEqual(intermediate.number, "2")
        XCTAssertNil(intermediate.previous)
        XCTAssertNil(intermediate.stationTerm)
    }

    func testForecastPlannedStaleAndFailedInputsCannotBecomeTheStationSign() throws {
        let planned = try XCTUnwrap(PlatformBoardPresentation(experience: experience(PlatformBoardQA.trip(at: now, current: nil))))
        XCTAssertNil(planned.number)
        XCTAssertTrue(planned.sourceText.contains("Timetable"))
        let missing = try XCTUnwrap(PlatformBoardPresentation(experience: experience(PlatformBoardQA.trip(at: now, current: nil, planned: nil))))
        XCTAssertNil(missing.number)
        let forecast = PlatformForecast(state: .likelyPlatform,
            zone: .init(id: "west", label: "West concourse", platforms: ["8"], probability: 1),
            candidates: [.init(platform: "8", probability: 1, observationCount: 20)], likelyPlatform: "8",
            confidence: .high, evidenceCount: 20, explanation: "", horizon: .underFifteenMinutes,
            modelVersion: "test", timetablePeriod: "test", stationMapVersion: "test",
            generatedAt: now, expiresAt: now.addingTimeInterval(180))
        let forecastTrip = PlatformBoardQA.trip(at: now, current: nil, planned: nil, forecast: forecast)
        let predicted = try XCTUnwrap(PlatformBoardPresentation(experience: experience(forecastTrip)))
        XCTAssertNil(predicted.number)
        XCTAssertNil(predicted.previous)
        XCTAssertFalse(predicted.sourceText.contains("8"))
        let trip = PlatformBoardQA.trip(at: now)
        for value in [
            experience(trip, failed: true), experience(trip, check: now.addingTimeInterval(-300)),
            experience(PlatformBoardQA.trip(at: now, observedAt: now.addingTimeInterval(-300))),
            experience(PlatformBoardQA.trip(at: now, observedAt: now.addingTimeInterval(30))),
        ] {
            let board = try XCTUnwrap(PlatformBoardPresentation(experience: value))
            XCTAssertNil(board.number)
            XCTAssertNil(board.previous)
        }
    }

    func testWatcherDepartedTrainCancelledCallAndOtherServiceNeverGetBoardingSign() {
        let trip = PlatformBoardQA.trip(at: now)
        XCTAssertNil(PlatformBoardPresentation(experience: experience(trip), watching: true))
        XCTAssertNil(PlatformBoardPresentation(experience: experience(trip), plans: [PlatformBoardQA.plan(trip)]))
        XCTAssertNil(PlatformBoardPresentation(experience: experience(trip, at: now.addingTimeInterval(1_200))))
        XCTAssertNil(PlatformBoardPresentation(experience: experience(PlatformBoardQA.trip(at: now, passed: true))))
        XCTAssertNil(PlatformBoardPresentation(experience: experience(PlatformBoardQA.trip(at: now, cancelled: true))))
        let other = JourneyPlanSegment(id: "other", kind: .rail, from: PlatformBoardQA.place(trip.stopTimes[0].station),
                                      to: PlatformBoardQA.place(trip.stopTimes[2].station), resolvedTripID: RailIdentifier(rawValue: "other"))
        XCTAssertNil(PlatformBoardPresentation(experience: experience(trip, segment: other)))
    }

    func testConsecutiveReportedAssignmentsOverrideTimetableAndInitialReportHasNoPreviousNumber() throws {
        var journal = TripChangeJournal()
        let previous = PlatformBoardQA.trip(at: now, current: "5", planned: "4")
        let latest = PlatformBoardQA.trip(at: now)
        journal.observe(previous: previous, current: latest, hadConfirmedCheck: true, at: now)
        let changed = try XCTUnwrap(PlatformBoardPresentation(experience: experience(latest), journal: journal))
        XCTAssertEqual(changed.previous, "5")
        XCTAssertNil(PlatformBoardPresentation(experience: experience(PlatformBoardQA.trip(at: now, planned: nil)))?.previous)
    }

    func testPlanOnlyTicketOpensReadableOriginalAndMultiTrainBookingDoesNotAssignItsSeatToEveryLeg() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalJourneyTicketStore(directory: directory)
        try await PlatformBoardQA.seedTicket(in: vault)
        let trip = PlatformBoardQA.trip(at: now)
        let plan = PlatformBoardQA.plan(trip)
        let single = try XCTUnwrap(PlatformBoardTicket.matching(vault.tickets, tripID: trip.id, plans: [plan]).first)
        XCTAssertEqual(single.coach, "6")
        XCTAssertEqual(single.seat, "14A")
        var partial = single.ticket
        partial.details.coach = nil
        let seatOnly = try XCTUnwrap(PlatformBoardTicket.matching([partial], tripID: trip.id, plans: [plan]).first)
        XCTAssertNil(seatOnly.coach)
        XCTAssertEqual(seatOnly.seat, "14A")
        partial.details = TicketTextDetails(coach: "6")
        let coachOnly = try XCTUnwrap(PlatformBoardTicket.matching([partial], tripID: trip.id, plans: [plan]).first)
        XCTAssertEqual(coachOnly.coach, "6")
        XCTAssertNil(coachOnly.seat)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: vault.payload(id: single.id))?.string).contains("14A"))
        let group = TrackedJourneyPlan(id: plan.id, createdAt: plan.createdAt, origin: plan.origin,
                                       destination: plan.destination, outbound: plan.outbound, returnDirection: plan.outbound,
                                       preExistingChildTripIDs: [])
        let groupTicket = try XCTUnwrap(PlatformBoardTicket.matching(vault.tickets, tripID: trip.id, plans: [group]).first)
        XCTAssertNil(groupTicket.coach)
        XCTAssertNil(groupTicket.seat)
        XCTAssertEqual(single.id, groupTicket.id)
        XCTAssertTrue(PlatformBoardTicket.matching(vault.tickets, tripID: RailIdentifier(rawValue: "different"), plans: [plan]).isEmpty)
    }
}
