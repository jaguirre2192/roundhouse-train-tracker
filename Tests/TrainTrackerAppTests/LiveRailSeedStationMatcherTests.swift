import TrainTrackerCore
import XCTest
@testable import TrainTracker

final class LiveRailSeedStationMatcherTests: XCTestCase {
    func testAmsterdamHyphenSeedMatchesProviderSpaceForDomesticAndCrossBorderRoutes() {
        let seed = LiveRailSeed.Station("Amsterdam Centraal", "Amsterdam-Centraal", "NL")
        let place = station("Amsterdam Centraal", country: "NL")
        XCTAssertEqual(LiveRailSeedStationMatcher.uniqueMatch(in: [place], seed: seed), place)
    }

    func testCaseDiacriticsPunctuationAndRepeatedSeparatorsAreFormattingOnly() {
        let seed = LiveRailSeed.Station("Zürich HB", "Zürich HB", "CH")
        let place = station("  ZURICH—(HB)  ", country: "CH")
        XCTAssertEqual(LiveRailSeedStationMatcher.uniqueMatch(in: [place], seed: seed), place)
    }

    func testCountryAndStationKindRemainRequired() {
        let seed = LiveRailSeed.Station("Amsterdam Centraal", "Amsterdam-Centraal", "NL")
        let wrongCountry = station("Amsterdam Centraal", country: "BE")
        let city = station("Amsterdam Centraal", country: "NL", kind: .city)
        XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [wrongCountry, city], seed: seed))
    }

    func testFinalHbfTokenMatchesExplicitHauptbahnhofLabelInEitherDirection() {
        for (expected, actual) in [("Berlin Hbf", "Berlin Hauptbahnhof"), ("Salzburg Hauptbahnhof", "Salzburg Hbf.")] {
            let seed = LiveRailSeed.Station(expected, expected, "DE")
            let place = station(actual, country: "DE")
            XCTAssertEqual(LiveRailSeedStationMatcher.uniqueMatch(in: [place], seed: seed), place)
        }
        let seed = LiveRailSeed.Station("Hbf Berlin", "Hbf Berlin", "DE")
        XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [station("Hauptbahnhof Berlin", country: "DE")], seed: seed))
    }

    func testMultipleMatchingStationIDsRemainAmbiguous() {
        let seed = LiveRailSeed.Station("Amsterdam Centraal", "Amsterdam-Centraal", "NL")
        let places = [station("Amsterdam Centraal", country: "NL", id: "first"),
                      station("Amsterdam-Centraal", country: "NL", id: "second")]
        XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: places, seed: seed))
    }

    func testSubstringWordOrderAndMissingWordBoundariesDoNotMatch() {
        let seed = LiveRailSeed.Station("Amsterdam Centraal", "Amsterdam-Centraal", "NL")
        for name in ["Amsterdam Centraal Metro", "Amsterdam", "Centraal Amsterdam", "AmsterdamCentraal"] {
            XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [station(name, country: "NL")], seed: seed), name)
        }
    }

    func testExplicitNativeIDChoosesOnlyTheQualifiedBoardingNode() {
        let seed = LiveRailSeed.Station("Trnava", "Trnava", "SK", nativeID: "sk-zsr_5613676")
        let domestic = station("Trnava", country: "SK", nativeID: "sk-zsr_5613676")
        let crossBorder = station("Trnava", country: "SK", nativeID: "ua-ukrzaliznytsya_5600195")
        XCTAssertEqual(LiveRailSeedStationMatcher.uniqueMatch(in: [crossBorder, domestic], seed: seed), domestic)
        XCTAssertEqual(LiveRailSeedStationMatcher.uniqueMatch(in: [domestic, crossBorder], seed: seed), domestic)
    }

    func testMissingQualifierTargetAndDuplicateQualifiedRecordsStayUnresolved() {
        let seed = LiveRailSeed.Station("Trnava", "Trnava", "SK", nativeID: "sk-zsr_5613676")
        let domestic = station("Trnava", country: "SK", nativeID: "sk-zsr_5613676")
        let foreign = station("Trnava", country: "SK", nativeID: "ua-ukrzaliznytsya_5600195")
        XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [foreign], seed: seed))
        XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [domestic, domestic], seed: seed))
        let unknown = LiveRailSeed.Station("Trnava", "Trnava", "SK", nativeID: "unknown")
        XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [domestic], seed: unknown))
    }

    func testNativeIDDoesNotBypassNameCountryOrStationKind() {
        let seed = LiveRailSeed.Station("Trnava", "Trnava", "SK", nativeID: "sk-zsr_5613676")
        for place in [station("Trnava predm.", country: "SK", nativeID: "sk-zsr_5613676"),
                      station("Trnava", country: "HR", nativeID: "sk-zsr_5613676"),
                      station("Trnava", country: "SK", kind: .city, nativeID: "sk-zsr_5613676")] {
            XCTAssertNil(LiveRailSeedStationMatcher.uniqueMatch(in: [place], seed: seed))
        }
    }

    private func station(_ name: String, country: String, id: String = "station", kind: RailPlace.Kind = .station,
                         nativeID: String? = nil) -> RailPlace {
        let identifier: String
        if let nativeID {
            let payload = Data([nativeID, country, "", ""].joined(separator: "\u{1f}").utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            identifier = "rail:transitous:station:\(payload)"
        } else {
            identifier = "eu:transitous:\(id)"
        }
        return RailPlace(id: RailIdentifier(rawValue: identifier), kind: kind,
                  displayName: name, context: "", countryCode: country, timeZoneIdentifier: "Europe/Amsterdam",
                  location: GeoCoordinate(latitude: 52.379, longitude: 4.9), eligibleModes: ["RAIL"], attributions: [])
    }
}
