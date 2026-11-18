import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneySearchCopyTests: XCTestCase {
    func testAuditValuesAreDeterministicUniqueAndExcludeForbiddenCommerceFamilies() {
        let first = JourneySearchCopy.allValues
        let second = JourneySearchCopy.allValues

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, Set(first).count)
        XCTAssertTrue(first.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        for value in first {
            XCTAssertFalse(
                JourneyCommerceCopyGuard.containsForbiddenCopy(value),
                "Forbidden Phase 1 copy family in: \(value)"
            )
        }
    }

    func testStaticCopyGuardRejectsHyphenatedSeatAvailability() {
        XCTAssertTrue(JourneyCommerceCopyGuard.containsForbiddenCopy("Seat-availability"))
        XCTAssertTrue(JourneyCommerceCopyGuard.containsForbiddenCopy("Seat availability"))
    }

    func testInteractiveJourneyActionsHaveExplicitLabelsAndOutcomeHints() {
        let actions = [
            JourneySearchCopy.Accessibility.swapPlaces,
            JourneySearchCopy.Accessibility.clearRecents,
            JourneySearchCopy.Accessibility.retryPlaceSearch,
            JourneySearchCopy.Accessibility.resultDetails(departure: "8:25 AM"),
            JourneySearchCopy.Accessibility.resultPage(title: "Earlier", direction: "Outbound"),
            JourneySearchCopy.Accessibility.selectResult(
                direction: "Outbound",
                optionLabel: "Departs 8:25 AM, arrives 10:12 AM"
            ),
            JourneySearchCopy.Accessibility.retryTrackingCheck,
            JourneySearchCopy.Accessibility.removeJourneyGroup,
            JourneySearchCopy.Accessibility.stopTrackingJourneyTrains,
            JourneySearchCopy.Accessibility.retryAlertSetup,
        ]

        for action in actions {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertFalse(action.hint.isEmpty)
            XCTAssertNotEqual(action.label, action.hint)
        }
    }

    func testResultSelectionActionPreservesOrderedJourneyFacts() {
        let facts = "Departs 8:25 AM, arrives 10:12 AM, duration 1 hour 47 minutes, direct, trackable"
        let action = JourneySearchCopy.Accessibility.selectResult(
            direction: "Outbound",
            optionLabel: facts
        )

        XCTAssertTrue(action.label.hasPrefix("Select outbound journey"))
        XCTAssertTrue(action.label.contains(facts))
    }

    func testResultVoiceOverOrderIncludesConditionalStatusBeforeTrackability() throws {
        let page = try fixturePage()
        let withStatus = JourneyOptionPresentation(option: page.options[1])
        let withoutStatus = JourneyOptionPresentation(option: page.options[0])

        XCTAssertEqual(
            withStatus.accessibilityParts.map(\.kind),
            [.departure, .arrival, .duration, .changes, .status, .trackability]
        )
        XCTAssertEqual(
            withoutStatus.accessibilityParts.map(\.kind),
            [.departure, .arrival, .duration, .changes, .status, .trackability]
        )
        XCTAssertTrue(withStatus.accessibilityParts[4].value.localizedCaseInsensitiveContains("canceled"))
        XCTAssertTrue(withStatus.accessibilityParts.last?.value.localizedCaseInsensitiveContains("trackable") == true)
    }

    func testResultVoiceOverOrderOmitsStatusOnlyWhenBackendSuppliesNoStatus() throws {
        let direct = try fixturePage().options[0]
        let withoutStatus = JourneyOption(
            id: direct.id,
            fingerprint: direct.fingerprint,
            startTime: direct.startTime,
            endTime: direct.endTime,
            duration: direct.duration,
            transferCount: direct.transferCount,
            segments: direct.segments.map { segment in
                guard case let .rail(rail) = segment else { return segment }
                return .rail(RailJourneySegment(
                    id: rail.id,
                    tripID: rail.tripID,
                    serviceDate: rail.serviceDate,
                    operatorName: rail.operatorName,
                    product: rail.product,
                    trainNumber: rail.trainNumber,
                    trainName: rail.trainName,
                    from: rail.from,
                    to: rail.to,
                    intermediateCalls: rail.intermediateCalls,
                    isCancelled: false,
                    isRealtime: false,
                    isTrackable: rail.isTrackable,
                    untrackableReason: rail.untrackableReason
                ))
            },
            badges: direct.badges,
            trackability: direct.trackability,
            realtimeFreshness: nil,
            attributions: direct.attributions,
            trackingToken: direct.trackingToken
        )

        XCTAssertEqual(
            JourneyOptionPresentation(option: withoutStatus).accessibilityParts.map(\.kind),
            [.departure, .arrival, .duration, .changes, .trackability]
        )
    }

    func testPlacePresentationUsesTextToDistinguishCityAndStation() {
        let city = place(kind: .city, name: "Paris", context: "All stations")
        let station = place(kind: .station, name: "Paris Gare du Nord", context: "Paris")

        let cityPresentation = RailPlacePickerPresentation(place: city)
        let stationPresentation = RailPlacePickerPresentation(place: station)

        XCTAssertTrue(cityPresentation.title.contains("All stations"))
        XCTAssertTrue(cityPresentation.detail.hasPrefix("City"))
        XCTAssertTrue(stationPresentation.detail.hasPrefix("Station"))
        XCTAssertNotEqual(cityPresentation.detail, stationPresentation.detail)
    }

    func testJourneyFailureCopyOnlyBlamesConnectionWhenActuallyOffline() {
        XCTAssertTrue(JourneySearchCopy.Form.searchFailureMessage(for: .offline).contains("connection"))
        XCTAssertFalse(JourneySearchCopy.Form.searchFailureMessage(for: .timedOut).contains("connection"))
        XCTAssertFalse(JourneySearchCopy.Form.searchFailureMessage(for: .serviceUnavailable).contains("connection"))
        XCTAssertFalse(JourneySearchCopy.Form.searchFailureMessage(for: .rateLimited).contains("connection"))
        XCTAssertFalse(JourneySearchCopy.Form.searchFailureMessage(for: .invalidRequest).contains("connection"))
        XCTAssertFalse(JourneySearchCopy.Form.searchFailureMessage(for: .invalidResponse).contains("connection"))
    }

    func testResultAttributionsExposeRequiredLinksAndOnlyValidBackendFeedNames() {
        let values = JourneySourceAttribution.presentations(from: [
            " Transitous ",
            "OpenStreetMap",
            "OpenStreetMap contributors",
            "Nederlandse Spoorwegen timetable",
            "",
            "https://untrusted.example/feed",
            "Bad\u{0007}Feed",
            "Cheapest fares",
            String(repeating: "x", count: 121),
            "transitous",
            "Nederlandse Spoorwegen timetable",
        ])

        XCTAssertEqual(values.map(\.title), [
            "Transitous",
            "OpenStreetMap contributors",
            "Nederlandse Spoorwegen timetable",
        ])
        XCTAssertEqual(values.map(\.kind), [.transitous, .openStreetMap, .feed])
        XCTAssertEqual(values.map(\.id).count, Set(values.map(\.id)).count)
        XCTAssertEqual(values[0].destination?.host, "transitous.org")
        XCTAssertEqual(values[1].destination?.host, "www.openstreetmap.org")
        XCTAssertEqual(values[2].destination?.absoluteString, JourneyDataSources.feedDirectoryURL.absoluteString)
    }

    func testStatusPresentationAlwaysIncludesTextAlongsideVisualStyling() throws {
        let presentation = JourneyOptionPresentation(option: try fixturePage().options[1])

        XCTAssertEqual(presentation.status, JourneySearchCopy.Status.cancelled)
        XCTAssertTrue(presentation.accessibilityLabel.contains(JourneySearchCopy.Status.cancelled))
    }

    func testOfficialSerbianTimetableAttributionLinksToItsOperator() throws {
        let values = JourneySourceAttribution.presentations(from: [
            "Srbijavoz official timetable", " srbijavoz official timetable ",
        ])
        let value = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(value.title, "Srbijavoz official timetable")
        XCTAssertEqual(value.kind, .feed)
        XCTAssertEqual(value.destination?.absoluteString, "https://webapi1.srbvoz.rs/ekarta/")
    }

    private func fixturePage() throws -> JourneySearchPage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "search-page",
            withExtension: "json"
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter().date(from: value) { return date }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.calendar = Calendar(identifier: .gregorian)
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "yyyy-MM-dd"
            guard let date = format.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid fixture date"
                )
            }
            return date
        }
        return try decoder.decode(JourneySearchPage.self, from: Data(contentsOf: url))
    }

    private func place(kind: RailPlace.Kind, name: String, context: String) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: "fixture:\(kind):\(name)"),
            kind: kind,
            displayName: name,
            context: context,
            countryCode: "FR",
            timeZoneIdentifier: "Europe/Paris",
            location: GeoCoordinate(latitude: 48.86, longitude: 2.35),
            eligibleModes: ["longDistanceRail"],
            attributions: ["Transitous", "OpenStreetMap contributors"]
        )
    }
}
