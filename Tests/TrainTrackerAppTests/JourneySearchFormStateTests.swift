import Foundation
import SwiftUI
import XCTest
import TrainTrackerCore
@testable import TrainTracker

final class JourneySearchFormStateTests: XCTestCase {
    func testTicketStationResolutionRejectsUnrelatedFallbacks() {
        let unrelatedStation = JourneySearchStoreFixtures.place(
            id: "eu:transitous:gb-london-waterloo",
            name: "London Waterloo",
            kind: .station,
            country: "GB",
            timeZone: "Europe/London"
        )

        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(
            named: "London St Pancras",
            from: [unrelatedStation]
        ))
    }

    func testDateOnlyTicketDepartureUsesNoonInTheOriginTimeZone() throws {
        let date = try XCTUnwrap(TicketJourneySearchPrefill.departureDate(
            "2026-08-14",
            timeZoneIdentifier: "Europe/Madrid"
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))

        XCTAssertEqual(calendar.component(.year, from: date), 2026)
        XCTAssertEqual(calendar.component(.month, from: date), 8)
        XCTAssertEqual(calendar.component(.day, from: date), 14)
        XCTAssertEqual(calendar.component(.hour, from: date), 12)
    }

    func testDefaultsAreOneWayDepartureSearchWithFourMaximumChanges() {
        let now = JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z")

        let form = JourneySearchFormState(outboundTime: now)

        XCTAssertNil(form.origin)
        XCTAssertNil(form.destination)
        XCTAssertFalse(form.outboundArriveBy)
        XCTAssertFalse(form.returnEnabled)
        XCTAssertFalse(form.returnArriveBy)
        XCTAssertEqual(form.returnTime, now)
        XCTAssertEqual(form.maximumTransfers, 4)
        XCTAssertFalse(form.canSearch)
    }

    @MainActor
    func testEnablingReturnClampsAnEarlierReturnToOutboundTime() {
        let outbound = JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(),
            form: JourneySearchFormState(
                origin: JourneySearchStoreFixtures.paris,
                destination: JourneySearchStoreFixtures.amsterdam,
                outboundTime: outbound,
                returnEnabled: false,
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z")
            )
        )

        store.setReturnEnabled(true)

        XCTAssertTrue(store.form.returnEnabled)
        XCTAssertEqual(store.form.returnTime, outbound)
    }

    @MainActor
    func testMovingOutboundLaterClampsAnEnabledReturn() {
        let newOutbound = JourneySearchStoreFixtures.date("2026-07-24T11:00:00Z")
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(),
            form: JourneySearchFormState(
                origin: JourneySearchStoreFixtures.paris,
                destination: JourneySearchStoreFixtures.amsterdam,
                outboundTime: JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z"),
                returnEnabled: true,
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
            )
        )

        store.setOutboundTime(newOutbound)

        XCTAssertEqual(store.form.outboundTime, newOutbound)
        XCTAssertEqual(store.form.returnTime, newOutbound)
    }

    @MainActor
    func testSettingReturnBeforeOutboundClampsToOutboundTime() {
        let outbound = JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(),
            form: JourneySearchFormState(
                origin: JourneySearchStoreFixtures.paris,
                destination: JourneySearchStoreFixtures.amsterdam,
                outboundTime: outbound,
                returnEnabled: true,
                returnTime: JourneySearchStoreFixtures.date("2026-07-24T11:00:00Z")
            )
        )

        store.setReturnTime(JourneySearchStoreFixtures.date("2026-07-24T09:00:00Z"))

        XCTAssertEqual(store.form.returnTime, outbound)
    }

    func testSwapExchangesPlacesWithoutChangingTimes() {
        let outbound = JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z")
        let returnTime = JourneySearchStoreFixtures.date("2026-07-25T08:00:00Z")
        var form = JourneySearchFormState(
            origin: JourneySearchStoreFixtures.paris,
            destination: JourneySearchStoreFixtures.amsterdam,
            outboundTime: outbound,
            returnEnabled: true,
            returnTime: returnTime
        )

        form.swapPlaces()

        XCTAssertEqual(form.origin, JourneySearchStoreFixtures.amsterdam)
        XCTAssertEqual(form.destination, JourneySearchStoreFixtures.paris)
        XCTAssertEqual(form.outboundTime, outbound)
        XCTAssertEqual(form.returnTime, returnTime)
    }

    func testSearchRequiresTwoDistinctSelectedPlaces() {
        var form = JourneySearchFormState()
        XCTAssertFalse(form.canSearch)

        form.origin = JourneySearchStoreFixtures.paris
        form.destination = JourneySearchStoreFixtures.paris
        XCTAssertFalse(form.canSearch)

        form.destination = JourneySearchStoreFixtures.amsterdam
        XCTAssertTrue(form.canSearch)
    }

    func testCriteriaUseTheLocalTimezoneAtTheRequestedEndpoint() {
        var form = JourneySearchFormState(
            origin: JourneySearchStoreFixtures.paris,
            destination: JourneySearchStoreFixtures.amsterdam,
            outboundTime: JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z"),
            returnEnabled: true,
            returnTime: JourneySearchStoreFixtures.date("2026-07-25T08:00:00Z")
        )

        XCTAssertEqual(form.outboundTimeZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(form.returnTimeZoneIdentifier, "Europe/Amsterdam")

        form.outboundArriveBy = true
        form.returnArriveBy = true

        XCTAssertEqual(form.outboundTimeZoneIdentifier, "Europe/Amsterdam")
        XCTAssertEqual(form.returnTimeZoneIdentifier, "Europe/Paris")
    }

    @MainActor
    func testClearingAPlaceResetsLoadedSearchStateAndDisablesSearch() async {
        let option = JourneySearchStoreFixtures.option(
            id: "outbound",
            fingerprint: "outbound",
            start: JourneySearchStoreFixtures.date("2026-07-24T08:00:00Z"),
            end: JourneySearchStoreFixtures.date("2026-07-24T10:00:00Z")
        )
        let store = makeJourneySearchStore(
            client: ScriptedJourneySearchClient(pages: [
                .success(JourneySearchStoreFixtures.page(options: [option])),
            ]),
            form: JourneySearchStoreFixtures.form(returnEnabled: false)
        )
        store.searchOutbound()
        await waitUntil { store.phase == .showingOutbound }

        store.setOrigin(nil)

        XCTAssertEqual(store.phase, .editing)
        XCTAssertNil(store.outboundPage)
        XCTAssertNil(store.selectedOutbound)
        XCTAssertFalse(store.form.canSearch)
    }
}

final class RailPlacePickerSearchPolicyTests: XCTestCase {
    func testSearchPolicyTrimsInputAndRequiresTwoCharacters() {
        XCTAssertEqual(RailPlacePickerSearchPolicy.normalized("  Pa  "), "Pa")
        XCTAssertFalse(RailPlacePickerSearchPolicy.shouldSearch(" P "))
        XCTAssertTrue(RailPlacePickerSearchPolicy.shouldSearch(" Pa "))
    }

    func testSearchPolicyUsesThreeHundredMillisecondDebounce() {
        XCTAssertEqual(RailPlacePickerSearchPolicy.debounce, .milliseconds(300))
    }

    func testCityPresentationUsesAllStationsSuffixAndVisibleKind() {
        let presentation = RailPlacePickerPresentation(
            place: JourneySearchStoreFixtures.paris
        )

        XCTAssertEqual(presentation.title, "Paris — All stations")
        XCTAssertEqual(presentation.systemImage, "building.2")
        XCTAssertTrue(presentation.detail.contains("City"))
        XCTAssertTrue(presentation.detail.contains("France"))
    }

    func testStationPresentationKeepsStationNameAndVisibleKind() {
        let station = JourneySearchStoreFixtures.place(
            id: "fr-paris-nord",
            name: "Paris Gare du Nord",
            kind: .station,
            country: "FR"
        )

        let presentation = RailPlacePickerPresentation(place: station)

        XCTAssertEqual(presentation.title, "Paris Gare du Nord")
        XCTAssertEqual(presentation.systemImage, TrainTrackerSymbol.train)
        XCTAssertTrue(presentation.detail.contains("Station"))
        XCTAssertTrue(presentation.detail.contains("France"))
    }

    func testLegacyCitySuffixIsNotDuplicated() {
        let city = JourneySearchStoreFixtures.place(
            id: "us-washington",
            name: "Washington DC — All stations",
            kind: .city,
            country: "US",
            timeZone: "America/New_York"
        )

        XCTAssertEqual(
            RailPlacePickerPresentation(place: city).title,
            "Washington DC — All stations"
        )
    }

    func testTimeZoneMetadataIsLocalizedAndExplicitlyLabeled() {
        let city = RailPlace(
            id: RailIdentifier(rawValue: "fixture:city:washington"),
            kind: .city,
            displayName: "Washington DC",
            context: "America/New_York",
            countryCode: "US",
            timeZoneIdentifier: "America/New_York",
            location: GeoCoordinate(latitude: 38.895, longitude: -77.036),
            eligibleModes: ["regionalRail"],
            attributions: ["Transitous"]
        )

        let detail = RailPlacePickerPresentation(place: city).detail

        XCTAssertTrue(detail.contains("Time zone:"))
        XCTAssertTrue(detail.contains("United States"))
        XCTAssertFalse(detail.contains("America/New_York"))
    }
}

final class RailStationMatchMergerTests: XCTestCase {
    func testSpecificMultiwordQueryRemovesPartialAndIrrelevantMatches() {
        let values: [RailStationMatch] = [
            match("NYP", name: "New York Penn", code: "NYP", source: .unitedStates),
            match("transitous-nyp", name: "NEW YORK PENN STATION", code: "us-Amtrak_NYP", source: .europe),
            match("newark", name: "NEWARK PENN STATION", code: "us-nj-NJ-Transit-Rail_107", source: .europe),
            match("via-new-york", name: "New York", code: "ca-Viarail_120", source: .europe),
            match("east-new-york", name: "East New York", code: "us-ny-LIRR_50", source: .europe),
            match("penne", name: "Penne", code: "fr-sncf-penne", country: "FR", source: .europe),
        ]

        let results = RailStationMatchMerger.merge(values, query: "New York Penn")

        XCTAssertEqual(results.map(\.station.displayName), ["New York Penn"])
    }

    func testBroadSingleWordQueryKeepsMultiplePennStations() {
        let values: [RailStationMatch] = [
            match("NYP", name: "New York Penn", code: "NYP", source: .unitedStates),
            match("newark", name: "Newark Penn Station", code: "NWK", source: .europe),
        ]

        XCTAssertEqual(
            RailStationMatchMerger.merge(values, query: "Penn").map(\.station.displayName),
            ["New York Penn", "Newark Penn Station"]
        )
    }

    func testSharedProviderTokenDoesNotCollapseDifferentStations() {
        let values: [RailStationMatch] = [
            match(
                "transitous-nyp",
                name: "New York Penn Station",
                code: "us-Amtrak_NYP",
                source: .europe
            ),
            match(
                "transitous-was",
                name: "Washington Union Station",
                code: "us-Amtrak_WAS",
                source: .europe
            ),
        ]

        XCTAssertEqual(RailStationMatchMerger.merge(values, query: "Station").count, 2)
    }

    func testStationSubtitleHidesOpaqueProviderIdentifier() {
        let station = match(
            "via-new-york",
            name: "New York",
            code: "ca-Viarail_120",
            source: .europe
        ).station

        let subtitle = StationSearchRowPresentation(
            station: station,
            locale: Locale(identifier: "en_US")
        ).subtitle

        XCTAssertEqual(subtitle, "United States")
        XCTAssertFalse(subtitle.contains("Viarail"))
    }

    private func match(
        _ id: String,
        name: String,
        code: String,
        country: String = "US",
        source: RailSource
    ) -> RailStationMatch {
        RailStationMatch(
            station: Station(
                id: RailIdentifier(rawValue: id),
                names: [LocalizedStationName(name)],
                codes: [.sourceNative: code],
                location: GeoCoordinate(latitude: 0, longitude: 0),
                countryCode: country,
                operatorHints: source == .unitedStates ? ["Amtrak"] : []
            ),
            source: source
        )
    }
}

final class JourneySearchFormLayoutTests: XCTestCase {
    func testPlaceRowsStackOnlyAtAccessibilityDynamicTypeSizes() {
        XCTAssertFalse(JourneySearchFormLayout.usesStackedPlaceRows(for: .xxxLarge))
        XCTAssertTrue(JourneySearchFormLayout.usesStackedPlaceRows(for: .accessibility1))
        XCTAssertTrue(JourneySearchFormLayout.usesStackedPlaceRows(for: .accessibility5))
    }

    /// The 2026-08-24 UI/UX audit found the primary Search action below the initial iPhone
    /// viewport because it followed the advanced Options disclosure.
    func testPrimaryActionFollowsTheJourneyControlsAndPrecedesAdvancedOptions() {
        let order = JourneySearchFormLayout.sectionOrder

        guard
            let route = order.firstIndex(of: .route),
            let outbound = order.firstIndex(of: .outbound),
            let returnTrip = order.firstIndex(of: .returnTrip),
            let primaryAction = order.firstIndex(of: .primaryAction),
            let advancedOptions = order.firstIndex(of: .advancedOptions)
        else {
            return XCTFail("Search form is missing a section")
        }

        XCTAssertLessThan(route, outbound)
        XCTAssertLessThan(outbound, returnTrip)
        XCTAssertLessThan(returnTrip, primaryAction)
        XCTAssertLessThan(primaryAction, advancedOptions)
    }

    func testSectionOrderRendersEverySearchFormSectionExactlyOnce() {
        let order = JourneySearchFormLayout.sectionOrder

        XCTAssertEqual(order.count, JourneySearchFormSection.allCases.count)
        XCTAssertEqual(Set(order), Set(JourneySearchFormSection.allCases))
    }
}
