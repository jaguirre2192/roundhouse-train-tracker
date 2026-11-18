import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class ImportedStationMatcherTests: XCTestCase {
    func testGermanMainStationAbbreviationPreservesCity() {
        let berlin = place("berlin", "Berlin Hbf", country: "DE", timeZone: "Europe/Berlin")
        let vienna = place("vienna", "Wien Hauptbahnhof", country: "AT", timeZone: "Europe/Vienna")
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Berlin Hauptbahnhof", from: [vienna, berlin]), berlin)
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Berlin Hauptbahnhof", from: [vienna]))
    }

    func testQualifiedTrnavaLookupKeepsCountryConstraintInMatching() {
        let slovakia = place("sk-trnava", "Trnava", country: "SK", timeZone: "Europe/Bratislava")
        let croatia = place("hr-trnava", "Trnava", country: "HR", timeZone: "Europe/Zagreb")
        let candidates = [croatia, slovakia]

        XCTAssertEqual(ImportedStationAlias.lookupQuery(for: " Trnava , Slovakia"), "Trnava")
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Trnava, Slovakia", from: candidates), slovakia)
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Trnava, Slovakia", from: [croatia]))
        XCTAssertNil(ImportedStationAlias.lookupQuery(for: "Trnava"))
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Trnava", from: candidates))
        XCTAssertEqual(ImportedStationAlias.lookupQuery(for: "Trnava, HR"), "Trnava")
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Trnava, HR", from: candidates), croatia)
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Trnava, HR", from: [slovakia]))
    }

    func testQualifiedLookupPreservesExplicitProviderAliasAndRejectsEmptyStation() {
        XCTAssertEqual(ImportedStationAlias.lookupQuery(for: "Beograd Centar, Serbia"), "Београд Центар")
        XCTAssertEqual(ImportedStationAlias.lookupQuery(for: "Petrovaradin, RS"), "Петроварадин")
        XCTAssertNil(ImportedStationAlias.lookupQuery(for: ", Slovakia"))
        XCTAssertNil(ImportedStationAlias.lookupQuery(for: "  , Slovakia"))
    }

    func testBelgradeCentreAliasesMatchCyrillicProviderStation() {
        let station = place("rs-Srbijavoz_7200080", "Београд центар", country: "RS", timeZone: "Europe/Belgrade")
        let other = place("other", "Београд Дунав", country: "RS", timeZone: "Europe/Belgrade")

        for name in ["Beograd Centar", "Belgrade Centre", "Belgrade Center", "Belgrade Centar", "Београд Центар",
                     "Beograd Centar-PROKOP", "Beograd Centar Prokop"] {
            XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: name, from: [other, station]), station, name)
            XCTAssertEqual(ImportedStationAlias.lookupQuery(for: name), "Београд Центар", name)
        }
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Beograd Centar, Serbia", from: [station]), station)
    }

    func testPetrovaradinAliasesMatchCyrillicProviderStation() {
        let station = place("rs-Srbijavoz_7216807", "Петроварадин", country: "RS", timeZone: "Europe/Belgrade")
        let noviSad = place("novi-sad", "Нови Сад", country: "RS", timeZone: "Europe/Belgrade")

        for name in ["Petrovaradin", "Петроварадин"] {
            XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: name, from: [noviSad, station]), station, name)
            XCTAssertEqual(ImportedStationAlias.lookupQuery(for: name), "Петроварадин", name)
        }
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Петроварадин, RS", from: [station]), station)
    }

    func testCyrillicSerbianImportsAlsoMatchLatinStationResults() {
        for name in ["Beograd Centar", "Belgrade Centre", "Belgrade Center", "Belgrade Centar",
                     "Beograd Centar-PROKOP", "Beograd Centar Prokop"] {
            let station = place("belgrade", name, country: "RS", timeZone: "Europe/Belgrade")
            XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Београд Центар", from: [station]), station, name)
        }
        let station = place("petrovaradin", "Petrovaradin", country: "RS", timeZone: "Europe/Belgrade")
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Петроварадин", from: [station]), station)
    }

    func testSerbianImportsPreferOfficialCatalogSpellingWhenBothFeedsAreReturned() {
        for (query, officialName, legacyName) in [
            ("Beograd Centar", "Beograd Centar-PROKOP", "Београд центар"),
            ("Петроварадин", "Petrovaradin", "Петроварадин"),
        ] {
            let official = place("official", officialName, country: "RS", timeZone: "Europe/Belgrade")
            let legacy = place("legacy", legacyName, country: "RS", timeZone: "Europe/Belgrade")
            XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: query, from: [legacy, official]), official)
        }
    }

    func testSerbianAliasesRejectWrongCountryTimeZoneCityAndStation() {
        for (importName, stationName, otherName) in [
            ("Beograd Centar", "Београд центар", "Београд Дунав"),
            ("Београд Центар", "Beograd Centar", "Beograd Dunav"),
            ("Petrovaradin", "Петроварадин", "Нови Сад"),
            ("Петроварадин", "Petrovaradin", "Novi Sad"),
        ] {
            let candidates = [
                place("foreign", stationName, country: "SK", timeZone: "Europe/Belgrade"),
                place("timezone", stationName, country: "RS", timeZone: "Europe/Bratislava"),
                place("city", stationName, kind: .city, country: "RS", timeZone: "Europe/Belgrade"),
                place("other", otherName, country: "RS", timeZone: "Europe/Belgrade"),
            ]
            XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: importName, from: candidates), importName)
            let station = place("correct", stationName, country: "RS", timeZone: "Europe/Belgrade")
            XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: importName + ", Slovakia", from: [station]), importName)
        }
    }

    func testSerbianAliasesDoNotSubstituteNoviSadOrBareBelgrade() {
        let petrovaradin = place("petrovaradin", "Петроварадин", country: "RS", timeZone: "Europe/Belgrade")
        for name in ["Novi Sad", "Нови Сад"] {
            XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: name, from: [petrovaradin]), name)
            XCTAssertNil(ImportedStationAlias.lookupQuery(for: name), name)
        }
        let belgrade = place("belgrade", "Београд центар", country: "RS", timeZone: "Europe/Belgrade")
        for name in ["Belgrade", "Beograd", "Београд"] {
            XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: name, from: [belgrade]), name)
            XCTAssertNil(ImportedStationAlias.lookupQuery(for: name), name)
        }
    }

    func testDCAliasesChooseUnionStationAheadOfMARCAndCityResults() {
        let union = place("union", "Washington Union Station")
        let candidates = [place("marc", "MARC Washington"), place("city", "Washington DC", kind: .city), union]

        for name in ["DC", "D.C.", "Washington, DC", "WAS", "DC, USA", "Washington, DC, United States"] {
            XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: name, from: candidates), union, name)
        }
    }

    func testNYCAliasesChoosePennStationAheadOfNewarkAndCityResults() {
        let penn = place("penn", "NEW YORK PENN STATION")
        let candidates = [place("newark", "NEWARK PENN STATION"), place("city", "New York", kind: .city), penn]

        for name in ["NYC", "NYP", "New York", "New York, NY", "NYC, United States", "New York Penn Station, NY"] {
            XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: name, from: candidates), penn, name)
        }
    }

    func testKnownAliasesRejectCitiesWrongCountriesAndUnrelatedStations() {
        let candidates = [
            place("city", "Washington Union Station", kind: .city),
            place("foreign", "Washington Union Station", country: "GB"),
            place("marc", "MARC Washington"),
        ]
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "DC", from: candidates))
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "NYC", from: [place("city", "New York", kind: .city)]))
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "NYC, France", from: [place("penn", "New York Penn Station")]))
    }

    func testQualifiedStationNamesPreserveCityAndCountryConstraints() {
        let london = place("london", "London St Pancras International", country: "GB")
        let paris = place("paris", "Paris Gare du Nord", country: "FR")

        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "London St Pancras, London, UK", from: [london]), london)
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Paris Gare du Nord, France", from: [paris]), paris)
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Paris Gare du Nord, United States", from: [paris]))
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Paris Gare du Nord, Lyon", from: [paris]))
    }

    func testShortOrEmptyNamesNeverUseAnArbitraryPartialResult() {
        let candidates = [place("paddington", "London Paddington"), place("pancras", "London St Pancras")]
        for name in ["", "   ", "---", "Lon", "London", "US"] {
            XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: name, from: candidates), name)
        }
    }

    func testSpecificImportedStationDoesNotCollapseToItsCityName() {
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(
            named: "London St Pancras",
            from: [place("city", "London", kind: .city), place("station", "London")]
        ))
    }

    func testAmbiguousPartialStationAndCrossCountryExactMatchesNeedCorrection() {
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "London St", from: [
            place("pancras", "London St Pancras"), place("other", "London St Other"),
        ]))
        XCTAssertNil(TicketJourneySearchPrefill.bestPlace(named: "Paris", from: [
            place("fr", "Paris", kind: .city, country: "FR"),
            place("us", "Paris", kind: .city),
        ]))
    }

    func testPortlandAliasesKeepMaineAndOregonSeparate() {
        let maine = place("maine", "Portland", timeZone: "America/New_York")
        let oregon = place("oregon", "Portland", timeZone: "America/Los_Angeles")

        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "POR", from: [oregon, maine]), maine)
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "PDX", from: [maine, oregon]), oregon)
        XCTAssertEqual(TicketJourneySearchPrefill.bestPlace(named: "Portland, ME, USA", from: [oregon, maine]), maine)
    }

    private func place(
        _ id: String,
        _ name: String,
        kind: RailPlace.Kind = .station,
        country: String = "US",
        timeZone: String = "America/New_York"
    ) -> RailPlace {
        JourneySearchStoreFixtures.place(id: id, name: name, kind: kind, country: country, timeZone: timeZone)
    }
}
