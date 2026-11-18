import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class JourneyTrackingHeaderPresentationTests: XCTestCase {
    func testScheduledNextArrivalDoesNotBorrowItsDepartureDelay() {
        let experience = present(trip(departureDelay: 30))
        XCTAssertEqual(experience.progress.phase, .underway)
        XCTAssertEqual(experience.timingLabel, "Timetable arrival")
        XCTAssertNil(experience.delayText)
        let header = JourneyTrackingHeaderPresentation(experience: experience)
        XCTAssertEqual(header.statusKind, .scheduled)
        XCTAssertEqual(header.statusText, "Timetable times")
    }

    func testNextArrivalDelayWinsOverAnOnTimeDeparture() {
        let experience = present(trip(arrivalDelay: 12, departureDelay: 0))
        XCTAssertEqual(experience.delayText, "12 min late")
        let header = JourneyTrackingHeaderPresentation(experience: experience)
        XCTAssertEqual(header.statusKind, .delayed)
        XCTAssertEqual(header.statusText, experience.delayText)
    }

    func testBeforeBoardingUsesDepartureRatherThanNextArrival() {
        let experience = present(trip(arrivalDelay: 25, boardingDelay: 8), at: base.addingTimeInterval(-65 * 60))
        XCTAssertTrue(experience.timingLabel.hasSuffix("departure"))
        let header = JourneyTrackingHeaderPresentation(experience: experience)
        XCTAssertEqual(header.statusText, "8 min late")
    }

    func testCancelledBoundaryNeverBorrowsAnotherStationsAssignment() {
        for cancelled in [0, 2] {
            let experience = present(trip(cancelledIndex: cancelled))
            XCTAssertFalse(experience.trip.isCancelled)
            XCTAssertEqual(experience.focusName, "Station \(cancelled)")
            XCTAssertEqual(experience.platformGuidance, .unavailable)
            let header = JourneyTrackingHeaderPresentation(experience: experience)
            XCTAssertNil(header.platformValue)
            XCTAssertEqual(header.statusText, "Stop canceled")
            XCTAssertEqual(header.statusKind, .cancelled)
        }
    }

    func testPositioningZoneRemainsQualifiedGuidanceRatherThanATrackNumber() {
        let experience = present(trip(forecast: forecast(.positioning)))
        let header = JourneyTrackingHeaderPresentation(experience: experience)
        XCTAssertEqual(header.platformValue, "Wait near the North concourse · likely tracks 1–4")
        XCTAssertEqual(header.platformLabel, "Roundhouse prediction")
        XCTAssertTrue(header.isPlatformPredicted)
        XCTAssertTrue(header.platformAccessibilityText.hasPrefix("Roundhouse prediction."))
        XCTAssertFalse(header.platformValue == "North concourse")
    }

    func testLikelyPlatformKeepsItsPredictionQualification() {
        let header = JourneyTrackingHeaderPresentation(experience: present(trip(forecast: forecast(.likelyPlatform))))
        XCTAssertEqual(header.platformValue, "Likely 4")
        XCTAssertEqual(header.platformLabel, "Track · prediction")
        XCTAssertTrue(header.platformAccessibilityText.contains("Likely track 4 · prediction"))
    }

    func testOfficialAssignmentKeepsFocusedStationNounAndFeedCredit() {
        let experience = present(trip())
        let header = JourneyTrackingHeaderPresentation(experience: experience)
        XCTAssertEqual(experience.focusName, "Station 1")
        XCTAssertEqual(header.platformValue, "3")
        XCTAssertEqual(header.platformLabel, "Track · via TestRail")
        XCTAssertEqual(header.platformAccessibilityText, "Track 3 · via TestRail")
    }

    func testElapsedTimetableDoesNotClaimConfirmedArrivalOrKeepTrackGuidance() {
        let experience = present(trip(), at: base.addingTimeInterval(180 * 60))
        XCTAssertEqual(experience.progress.phase, .ended)
        XCTAssertFalse(experience.progress.evidence.isArrivalConfirmed)
        let header = JourneyTrackingHeaderPresentation(experience: experience)
        XCTAssertEqual(header.statusText, RunningStatusWords.arrivalUnconfirmed)
        XCTAssertNil(header.platformValue)
    }

    private var base: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func present(_ trip: TrainTrip, at date: Date? = nil) -> JourneyExperiencePresentation {
        JourneyExperiencePresentation(
            trip: trip, timeZones: TripDetailTimeZoneContext(trip: trip),
            referenceDate: date ?? base, lastSuccessfulCheck: date ?? base
        )
    }

    private func trip(
        arrivalDelay: Int? = nil, departureDelay: Int? = nil, boardingDelay: Int? = nil,
        cancelledIndex: Int? = nil, forecast: PlatformForecast? = nil
    ) -> TrainTrip {
        let boarding = base.addingTimeInterval(-60 * 60)
        let arrival = base.addingTimeInterval(30 * 60)
        let departure = arrival.addingTimeInterval(5 * 60)
        let stops = [
            StopTime(
                station: station(0), sequence: 0, scheduledDeparture: boarding,
                expectedDeparture: boardingDelay.map { boarding.addingTimeInterval(Double($0) * 60) },
                expectedPlatform: "1", platformKind: .track, platformSource: "TestRail",
                isCancelled: cancelledIndex == 0
            ),
            StopTime(
                station: station(1), sequence: 1, scheduledArrival: arrival, scheduledDeparture: departure,
                expectedArrival: arrivalDelay.map { arrival.addingTimeInterval(Double($0) * 60) },
                expectedDeparture: departureDelay.map { departure.addingTimeInterval(Double($0) * 60) },
                expectedPlatform: forecast == nil ? "3" : nil, platformForecast: forecast,
                platformKind: .track, platformSource: "TestRail", isCancelled: cancelledIndex == 1
            ),
            StopTime(
                station: station(2), sequence: 2, scheduledArrival: base.addingTimeInterval(120 * 60),
                expectedPlatform: "9", platformKind: .track, platformSource: "TestRail",
                isCancelled: cancelledIndex == 2
            ),
        ]
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:fixture:tracking-header"), source: "fixture", serviceDate: boarding,
            operatorName: "Fixture Rail", product: "Express", headsign: "Station 2", stopTimes: stops,
            capabilities: .init(hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
    }

    private func station(_ index: Int) -> Station {
        Station(
            id: RailIdentifier(rawValue: "us:fixture:header-station-\(index)"), names: [.init("Station \(index)")],
            location: .init(latitude: 40 + Double(index) * 0.1, longitude: -74), countryCode: "US"
        )
    }

    private func forecast(_ state: PlatformForecast.State) -> PlatformForecast {
        PlatformForecast(
            state: state, zone: .init(id: "north", label: "North concourse", platforms: ["1", "4"], probability: 0.8),
            candidates: [], likelyPlatform: state == .likelyPlatform ? "4" : nil, confidence: .medium,
            evidenceCount: 20, explanation: "Illustrative fixture", horizon: .underFifteenMinutes,
            modelVersion: "fixture", timetablePeriod: "fixture", stationMapVersion: "fixture",
            generatedAt: base, expiresAt: base.addingTimeInterval(60 * 60)
        )
    }
}
