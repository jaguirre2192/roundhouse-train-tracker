import Foundation
import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class JourneyResultsPresentationTests: XCTestCase {
    func testContextPresentsOutboundAndReturnRoutesInLocalSearchTime() {
        let form = JourneySearchStoreFixtures.form()

        var outbound = JourneyResultsContext(direction: .outbound, form: form)
        var returnContext = JourneyResultsContext(direction: .return, form: form)
        outbound.deviceTimeZone = TimeZone(identifier: "Europe/Paris")!
        returnContext.deviceTimeZone = TimeZone(identifier: "Europe/Amsterdam")!

        XCTAssertEqual(outbound.routeTitle, "Paris → Amsterdam")
        XCTAssertEqual(outbound.timingSummary, "Fri, Jul 24 · After 8:25 AM")
        XCTAssertEqual(returnContext.routeTitle, "Amsterdam → Paris")
        XCTAssertEqual(returnContext.timingSummary, "Sat, Jul 25 · After 8:25 AM")

        // A traveller on another clock is told which zone the search time is in.
        outbound.deviceTimeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(outbound.timingSummary, "Fri, Jul 24 · After 8:25 AM GMT+2")
    }

    func testContextUsesArriveByLanguage() {
        var form = JourneySearchStoreFixtures.form(returnEnabled: false)
        form.outboundArriveBy = true

        let context = JourneyResultsContext(direction: .outbound, form: form)

        XCTAssertTrue(context.timingSummary.contains("· By"))
    }

    func testSortOrdersUseVisibleJourneyCriteriaAndStableTies() {
        let earlySlow = option(
            id: "early-slow",
            start: "2026-07-24T06:00:00Z",
            end: "2026-07-24T10:00:00Z",
            changes: 2
        )
        let laterFast = option(
            id: "later-fast",
            start: "2026-07-24T07:00:00Z",
            end: "2026-07-24T09:00:00Z",
            changes: 1
        )
        let laterDirect = option(
            id: "later-direct",
            start: "2026-07-24T07:30:00Z",
            end: "2026-07-24T10:30:00Z",
            changes: 0
        )
        let options = [laterDirect, laterFast, earlySlow]

        XCTAssertEqual(
            JourneyResultSortOrder.departure.sorted(options).map(\.id),
            ["early-slow", "later-fast", "later-direct"]
        )
        XCTAssertEqual(
            JourneyResultSortOrder.fastest.sorted(options).map(\.id),
            ["later-fast", "later-direct", "early-slow"]
        )
        XCTAssertEqual(
            JourneyResultSortOrder.fewestChanges.sorted(options).map(\.id),
            ["later-direct", "later-fast", "early-slow"]
        )
    }

    func testFinalPresentationKeepsImportedTrainFirstAndExplainsNumberMatch() {
        let options = importedOptions()
        let rows = JourneyResultsPresentation.rows(
            options: options,
            sortOrder: .defaultOrder(preferredTrainNumber: "90 32"),
            preferredTrainNumber: "90 32"
        )

        XCTAssertEqual(rows.map(\.id), ["imported", "earlier"])
        XCTAssertEqual(rows.first?.importedTrainMatchLabel, "Train number matches import")
        XCTAssertTrue(rows.first?.accessibilityLabel.contains("Train number matches import") == true)
        XCTAssertNil(rows.last?.importedTrainMatchLabel)
    }

    func testExplicitDepartureSortOverridesImportedPreferenceWithoutLosingMatchLabel() {
        let rows = JourneyResultsPresentation.rows(
            options: importedOptions().reversed(),
            sortOrder: .departure,
            preferredTrainNumber: "9032"
        )

        XCTAssertEqual(rows.map(\.id), ["earlier", "imported"])
        XCTAssertNil(rows.first?.importedTrainMatchLabel)
        XCTAssertNotNil(rows.last?.importedTrainMatchLabel)
    }

    func testUnmatchedOrBlankImportedNumberNeverLabelsAnotherTrain() {
        for number in ["903", "---", ""] {
            let rows = JourneyResultsPresentation.rows(
                options: importedOptions(),
                sortOrder: .defaultOrder(preferredTrainNumber: number),
                preferredTrainNumber: number
            )
            XCTAssertEqual(rows.map(\.id), ["earlier", "imported"])
            XCTAssertTrue(rows.allSatisfy { $0.importedTrainMatchLabel == nil })
        }
    }

    func testOrdinarySearchDoesNotOfferImportedTrainSort() {
        XCTAssertEqual(JourneyResultSortOrder.defaultOrder(preferredTrainNumber: nil), .departure)
        XCTAssertEqual(JourneyResultSortOrder.availableOrders(preferredTrainNumber: nil), [.departure, .fastest, .fewestChanges])
        XCTAssertEqual(JourneyResultSortOrder.defaultOrder(preferredTrainNumber: "9032"), .importedTrain)
        XCTAssertTrue(JourneyResultSortOrder.availableOrders(preferredTrainNumber: "9032").contains(.importedTrain))
    }

    private func importedOptions() -> [JourneyOption] {
        [
            JourneySearchStoreFixtures.option(
                id: "earlier", fingerprint: "earlier",
                start: JourneySearchStoreFixtures.date("2026-08-14T09:00:00Z"),
                end: JourneySearchStoreFixtures.date("2026-08-14T11:00:00Z"),
                trainNumber: "9010"
            ),
            JourneySearchStoreFixtures.option(
                id: "imported", fingerprint: "imported",
                start: JourneySearchStoreFixtures.date("2026-08-14T10:00:00Z"),
                end: JourneySearchStoreFixtures.date("2026-08-14T12:00:00Z"),
                trainNumber: "9032"
            ),
        ]
    }

    private func option(
        id: String,
        start: String,
        end: String,
        changes: Int
    ) -> JourneyOption {
        JourneySearchStoreFixtures.option(
            id: id,
            fingerprint: id,
            start: JourneySearchStoreFixtures.date(start),
            end: JourneySearchStoreFixtures.date(end),
            transferCount: changes
        )
    }
}
