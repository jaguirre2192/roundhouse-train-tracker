import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

@MainActor
final class TrainActivityPresentationTests: XCTestCase {
    private let referenceDate = TripDetailTimeZoneFixtures.date("2026-09-15T22:10:00Z")

    func testStaleContentHidesThePlatformAndCompactOperationalClock() {
        for staleSource in ["activitykit", "expired", "unchecked"] {
            let presentation = presentation(
                timingBasis: .estimated, platform: "12", platformBasis: .reported,
                platformChanged: true, delayMinutes: 12,
                systemStale: staleSource == "activitykit", expired: staleSource == "expired",
                hasCheck: staleSource != "unchecked"
            )
            XCTAssertTrue(presentation.isStale, staleSource)
            XCTAssertNil(presentation.platform, staleSource)
            // The island keeps the saved time (dimmed, without the live "~") instead of an action word.
            XCTAssertFalse(presentation.compactText.contains("~"), staleSource)
            XCTAssertNotEqual(presentation.compactText, "Refresh", staleSource)
            XCTAssertEqual(presentation.symbol, TrainTrackerSymbol.train, staleSource)
            XCTAssertEqual(presentation.shortStatus, "Saved", staleSource)
            XCTAssertEqual(presentation.timingLabel, "Saved estimate", staleSource)
            XCTAssertEqual(presentation.shortTimingLabel, "Saved", staleSource)
            if staleSource == "unchecked" {
                XCTAssertEqual(presentation.headerStatus, "Not checked yet", staleSource)
                XCTAssertEqual(presentation.evidenceText, "Not checked yet · Saved times shown", staleSource)
            } else {
                XCTAssertEqual(presentation.headerStatus, "Saved times", staleSource)
                XCTAssertTrue(presentation.evidenceText.hasSuffix(" · Saved times shown"), staleSource)
                XCTAssertTrue(presentation.evidenceText.contains("hecked"), staleSource)
            }
            XCTAssertEqual(presentation.actionTitle, "Open to refresh", staleSource)
            XCTAssertFalse(presentation.accessibilitySummary.contains("Platform changed"), staleSource)
            XCTAssertFalse(presentation.accessibilitySummary.contains("12 min late"), staleSource)
        }
    }

    func testCancellationSuppressesTimePlatformAndDelayEvenWhenStateContainsThem() {
        for isStopCancelled in [false, true] {
            let presentation = presentation(
                phase: .cancelled, timingBasis: .estimated, platform: "12", platformBasis: .reported,
                platformChanged: true, delayMinutes: 12, isStopCancelled: isStopCancelled
            )
            XCTAssertTrue(presentation.isCancelled)
            XCTAssertFalse(presentation.hasDelay)
            XCTAssertNil(presentation.eventDate)
            XCTAssertNil(presentation.timeText)
            XCTAssertNil(presentation.platform)
            XCTAssertEqual(presentation.phaseTitle, isStopCancelled ? "Stop canceled" : "Canceled")
            XCTAssertEqual(presentation.compactText, "Canceled")
            XCTAssertEqual(presentation.shortStatus, "Canceled")
            XCTAssertEqual(presentation.focusLabel, "Check travel options")
            XCTAssertFalse(presentation.accessibilitySummary.contains("Platform changed"))
            XCTAssertFalse(presentation.accessibilitySummary.contains("Estimated 12 min late"))
        }
    }

    func testUnknownStationTimeZoneUsesExplicitUTCInsteadOfDeviceTime() {
        var presentation = presentation(timeZoneIdentifier: nil)
        presentation.locale = Locale(identifier: "en_GB")
        XCTAssertEqual(presentation.timeZone.secondsFromGMT(for: referenceDate), 0)
        XCTAssertEqual(presentation.timeZoneText, "UTC")
        XCTAssertEqual(presentation.compactText, "22:40")
        XCTAssertTrue(presentation.accessibilitySummary.contains("Station time zone unavailable. Time shown in UTC."))
    }

    func testScheduledAndEstimatedTimesRetainDistinctEvidenceLabels() {
        var scheduled = presentation(timingBasis: .scheduled)
        var estimated = presentation(timingBasis: .estimated)
        scheduled.locale = Locale(identifier: "en_GB")
        estimated.locale = Locale(identifier: "en_GB")
        XCTAssertEqual(scheduled.timingLabel, "Timetable")
        XCTAssertEqual(scheduled.focusLabel, "Next scheduled stop")
        XCTAssertEqual(scheduled.evidenceText, "From the timetable")
        XCTAssertEqual(scheduled.compactText, "18:40")
        XCTAssertEqual(estimated.timingLabel, "Estimated")
        XCTAssertEqual(estimated.focusLabel, "Next expected stop")
        XCTAssertEqual(estimated.evidenceText, "Provider estimate")
        XCTAssertEqual(estimated.compactText, "~18:40")

        // The island follows the traveller's clock style; AM/PM is dropped to fit.
        scheduled.locale = Locale(identifier: "en_US")
        estimated.locale = Locale(identifier: "en_US")
        XCTAssertEqual(scheduled.compactText, "6:40")
        XCTAssertEqual(estimated.compactText, "~6:40")
    }

    func testPlatformCopyKeepsReportedScheduledAndPredictedValuesDistinct() {
        let reported = presentation(platform: "4", platformBasis: .reported)
        let changed = presentation(platform: "7", platformBasis: .reported, platformChanged: true)
        let scheduled = presentation(platform: "8", platformBasis: .scheduled)
        let predicted = presentation(platform: "9", platformBasis: .predicted)
        XCTAssertEqual(reported.platformLabel, "Reported platform")
        XCTAssertEqual(changed.platformLabel, "Platform changed")
        XCTAssertEqual(scheduled.platformLabel, "Scheduled platform")
        XCTAssertEqual(predicted.platformLabel, "Likely platform")
        XCTAssertEqual(predicted.platform, "9")
        XCTAssertEqual(predicted.evidenceText, "Check station displays")
        XCTAssertFalse(predicted.accessibilitySummary.lowercased().contains("confirmed"))
    }

    func testAmtrakTrackAndSourceLabelsAndOlderContentFallback() throws {
        let track = presentation(platform: "17", platformBasis: .reported, platformKind: .track, platformSource: "Amtraker")
        XCTAssertEqual(track.platformNoun, "Track")
        XCTAssertEqual(track.platformLabel, "Track via Amtraker")
        XCTAssertEqual(presentation(platform: "17", platformBasis: .reported, platformChanged: true, platformKind: .track).platformLabel, "Track changed")
        XCTAssertEqual(presentation(platformKind: .track).platformLabel, "Track")

        // Content pushed by a server that predates the optional fields keeps the original copy.
        let legacy = try JSONDecoder().decode(TrainLiveActivityState.self, from: Data("""
        {"schemaVersion":1,"phase":"upcoming","focusName":"Washington Union","eventTime":null,"timeZoneIdentifier":null,
         "timingBasis":"unavailable","platform":"4","platformBasis":"reported","platformChanged":false,"delayMinutes":null,
         "checkedAt":null,"validUntil":1,"isStopCancelled":false}
        """.utf8))
        XCTAssertNil(legacy.platformKind)
        XCTAssertNil(legacy.platformSource)
        let unknownKind = try JSONDecoder().decode(TrainLiveActivityState.self, from: Data("""
        {"schemaVersion":1,"phase":"upcoming","focusName":"Washington Union","timingBasis":"unavailable","platform":"4",
         "platformBasis":"reported","platformChanged":false,"validUntil":1,"isStopCancelled":false,"platformKind":"gate"}
        """.utf8))
        XCTAssertNil(unknownKind.platformKind, "An unknown future kind is ignored rather than failing the whole update")
        let encoded = try JSONEncoder().encode(TrainLiveActivityState(phase: .upcoming, focusName: "WAS", platform: "17",
            platformBasis: .reported, validUntil: 1, platformKind: .track, platformSource: "Amtraker"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["platformKind"] as? String, "track")
        XCTAssertEqual(object["platformSource"] as? String, "Amtraker")
    }

    func testEndedWindowKeepsItsLastTimeWithoutClaimingActualArrival() {
        let scheduled = presentation(phase: .ended, timingBasis: .scheduled, platform: "4", platformBasis: .reported)
        let estimated = presentation(phase: .ended, timingBasis: .estimated, delayMinutes: 15)
        XCTAssertEqual(scheduled.phaseTitle, "Journey ended")
        XCTAssertEqual(scheduled.timingLabel, "Timetable arrival")
        XCTAssertEqual(estimated.timingLabel, "Last arrival estimate")
        XCTAssertEqual(estimated.evidenceText, "Last estimate has passed")
        XCTAssertEqual(estimated.compactText, "Ended")
        XCTAssertFalse(estimated.hasDelay)
        XCTAssertNil(scheduled.platform)
        XCTAssertFalse(estimated.accessibilitySummary.lowercased().contains("arrived"))
    }

    func testUnavailableDetailsCannotPresentAnOperationalTimeOrPlatform() {
        let presentation = presentation(phase: .unavailable, platform: "12", platformBasis: .reported)
        XCTAssertNil(presentation.eventDate)
        XCTAssertNil(presentation.timeText)
        XCTAssertNil(presentation.platform)
        XCTAssertEqual(presentation.phaseTitle, "Details unavailable")
        XCTAssertEqual(presentation.compactText, "—")
        XCTAssertEqual(presentation.evidenceText, "Open for journey details")
    }

    func testLockScreenBoardingSignIsScopedToRiderExactCallReportedNumberAndFreshDeparture() throws {
        let trip = PlatformBoardQA.trip(at: referenceDate)
        let selection = try XCTUnwrap(TrainLiveActivitySelection(trip: trip, segment: nil, plans: []))
        let projection = selection.projection(at: referenceDate, checkedAt: referenceDate, refreshFailed: false)
        let state = try JSONDecoder().decode(TrainLiveActivityState.self, from: JSONEncoder().encode(projection.state))
        XCTAssertEqual(state.boardingPlatformSequence, selection.boarding.sequence)
        func displayed(_ state: TrainLiveActivityState, riding: Bool?, now: Date) -> String? {
            TrainActivityPresentation(attributes: selection.attributes(at: referenceDate, isRiding: riding),
                                      state: state, isStale: false, referenceDate: now).boardingPlatform
        }
        XCTAssertEqual(displayed(state, riding: true, now: referenceDate), "7")
        XCTAssertNil(displayed(state, riding: false, now: referenceDate))
        XCTAssertNil(displayed(state, riding: nil, now: referenceDate))
        XCTAssertNil(displayed(state, riding: true, now: referenceDate.addingTimeInterval(300)))
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        for marker in [selection.boarding.sequence + 1, nil] as [Int?] {
            wire["boardingPlatformSequence"] = marker
            let other = try JSONDecoder().decode(TrainLiveActivityState.self, from: JSONSerialization.data(withJSONObject: wire))
            XCTAssertNil(displayed(other, riding: true, now: referenceDate))
        }
        let oldTrack = PlatformBoardQA.trip(at: referenceDate, observedAt: referenceDate.addingTimeInterval(-600))
        let retained = TrainLiveActivityProjection(trip: oldTrack, referenceDate: referenceDate, lastSuccessfulCheck: referenceDate)
        XCTAssertNil(displayed(retained.state, riding: true, now: referenceDate))
    }

    private func presentation(
        phase: TrainLiveActivityState.Phase = .underway,
        timingBasis: TrainLiveActivityState.TimingBasis = .scheduled,
        timeZoneIdentifier: String? = "America/New_York",
        platform: String? = nil,
        platformBasis: TrainLiveActivityState.PlatformBasis = .unavailable,
        platformChanged: Bool = false,
        platformKind: PlatformKind? = nil,
        platformSource: String? = nil,
        delayMinutes: Int? = nil,
        isStopCancelled: Bool = false,
        systemStale: Bool = false,
        expired: Bool = false,
        hasCheck: Bool = true
    ) -> TrainActivityPresentation {
        let trip = TripDetailTimeZoneFixtures.easternRoute().trip
        let now = referenceDate.timeIntervalSince1970
        let attributes = TrainJourneyAttributes(
            activityKey: "test", tripID: trip.id.rawValue,
            boardingStationID: trip.stopTimes[1].station.id.rawValue,
            alightingStationID: trip.stopTimes[2].station.id.rawValue,
            serviceName: trip.product, originName: trip.stopTimes[1].station.displayName,
            destinationName: trip.stopTimes[2].station.displayName, startedAt: now
        )
        let state = TrainLiveActivityState(
            phase: phase, focusName: trip.stopTimes[1].station.displayName, eventTime: now + 1_800,
            timeZoneIdentifier: timeZoneIdentifier, timingBasis: timingBasis,
            platform: platform, platformBasis: platformBasis, platformChanged: platformChanged,
            delayMinutes: delayMinutes, checkedAt: hasCheck ? now - 15 : nil,
            validUntil: expired ? now : now + 180, isStopCancelled: isStopCancelled,
            platformKind: platformKind, platformSource: platformSource
        )
        return TrainActivityPresentation(
            attributes: attributes, state: state, isStale: systemStale, referenceDate: referenceDate
        )
    }
}
