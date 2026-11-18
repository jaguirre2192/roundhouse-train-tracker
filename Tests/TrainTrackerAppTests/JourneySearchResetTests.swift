import XCTest
@testable import TrainTracker

final class JourneySearchResetTests: XCTestCase {
    @MainActor
    func testOriginEditClearsBothSelections() async {
        let store = await makeReviewingJourneyStore()
        store.setOrigin(JourneySearchStoreFixtures.place(id: "lyon", name: "Lyon"))
        assertJourneySelectionsCleared(store)
    }

    @MainActor
    func testDestinationEditClearsBothSelections() async {
        let store = await makeReviewingJourneyStore()
        store.setDestination(JourneySearchStoreFixtures.place(id: "rotterdam", name: "Rotterdam"))
        assertJourneySelectionsCleared(store)
    }

    @MainActor
    func testOutboundTimeEditClearsBothSelections() async {
        let store = await makeReviewingJourneyStore()
        store.setOutboundTime(JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z"))
        assertJourneySelectionsCleared(store)
    }

    @MainActor
    func testOutboundModeEditClearsBothSelections() async {
        let store = await makeReviewingJourneyStore()
        store.setOutboundArriveBy(true)
        assertJourneySelectionsCleared(store)
    }

    @MainActor
    func testDisablingReturnPreservesOutboundAndClearsReturn() async {
        let store = await makeReviewingJourneyStore()
        let outbound = store.selectedOutbound
        store.setReturnEnabled(false)

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertFalse(store.form.returnEnabled)
        XCTAssertEqual(store.phase, .reviewing)
    }

    @MainActor
    func testReturnTimeEditPreservesOutboundAndClearsReturn() async {
        let store = await makeReviewingJourneyStore()
        let outbound = store.selectedOutbound
        store.setReturnTime(JourneySearchStoreFixtures.date("2026-07-25T08:00:00Z"))

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.phase, .showingReturn)
    }

    @MainActor
    func testReturnModeEditPreservesOutboundAndClearsReturn() async {
        let store = await makeReviewingJourneyStore()
        let outbound = store.selectedOutbound
        store.setReturnArriveBy(true)

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.phase, .showingReturn)
    }

    @MainActor
    func testDirectOnlyPreservesVisibleOutboundAndClearsOnlyHiddenReturn() async {
        let outbound = journeyOutboundOption()
        let connectingReturn = journeyReturnOption(transferCount: 1)
        let store = await makeReviewingJourneyStore(
            outbound: outbound,
            returnOption: connectingReturn
        )
        store.setDirectOnly(true)

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertNil(store.selectedReturn)
        XCTAssertEqual(store.phase, .showingReturn)
    }

    @MainActor
    func testDirectOnlyPreservesBothSelectionsWhenBothRemainVisible() async {
        let store = await makeReviewingJourneyStore()
        let outbound = store.selectedOutbound
        let returnOption = store.selectedReturn
        store.setDirectOnly(true)

        XCTAssertEqual(store.selectedOutbound, outbound)
        XCTAssertEqual(store.selectedReturn, returnOption)
        XCTAssertEqual(store.phase, .reviewing)
    }

    @MainActor
    func testMaximumTransfersEditClearsBothSelections() async {
        let store = await makeReviewingJourneyStore()
        store.setMaximumTransfers(1)
        assertJourneySelectionsCleared(store)
    }

    @MainActor
    func testEditSearchReturnsReviewToPopulatedFormAndClearsSearchState() async {
        let store = await makeReviewingJourneyStore()
        let populatedForm = store.form

        XCTAssertTrue(store.canEditSearch)
        store.editSearch()

        XCTAssertEqual(store.form, populatedForm)
        assertJourneySelectionsCleared(store)
        XCTAssertFalse(store.isJourneyTaskActive)
    }

    @MainActor
    func testEditSearchReturnsOutboundResultsToPopulatedForm() async {
        let outbound = journeyOutboundOption()
        let client = ScriptedJourneySearchClient(pages: [
            .success(JourneySearchStoreFixtures.page(options: [outbound])),
        ])
        let store = makeJourneySearchStore(client: client)
        let populatedForm = store.form
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }

        XCTAssertTrue(store.canEditSearch)
        store.editSearch()

        XCTAssertEqual(store.form, populatedForm)
        assertJourneySelectionsCleared(store)
    }

    @MainActor
    func testEditSearchReturnsReturnResultsToPopulatedForm() async {
        let store = await makeReviewingJourneyStore()
        store.editReturn()
        let populatedForm = store.form
        XCTAssertEqual(store.phase, .showingReturn)

        XCTAssertTrue(store.canEditSearch)
        store.editSearch()

        XCTAssertEqual(store.form, populatedForm)
        assertJourneySelectionsCleared(store)
    }
}
