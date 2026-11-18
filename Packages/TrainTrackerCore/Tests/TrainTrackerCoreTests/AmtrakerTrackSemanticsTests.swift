import Foundation
import Testing
@testable import TrainTrackerCore

/// Regression coverage for the September 15, 2026 Washington Union report: Amtraker returned an
/// empty platform for Acela 2120 while the station board showed Gate F / Track 17.
private func washingtonTrain(platform: String) throws -> TrainTrip {
    let train = try JSONDecoder().decode(AmtrakerTrainDTO.self, from: Data("""
    {
      "trainID": "2120-15", "trainNum": "2120", "routeName": "Acela",
      "stations": [
        {"name": "Washington Union", "code": "WAS", "tz": "America/New_York",
         "schDep": "2026-09-15T17:05:00-04:00", "dep": "2026-09-15T17:05:00-04:00",
         "status": "Enroute", "platform": "\(platform)"},
        {"name": "New York Penn", "code": "NYP", "tz": "America/New_York",
         "schArr": "2026-09-15T20:05:00-04:00", "arr": "2026-09-15T20:05:00-04:00",
         "status": "Enroute", "platform": ""}
      ]
    }
    """.utf8))
    let now = try #require(RailDateParser.parse("2026-09-15T16:50:52-04:00"))
    return AmtrakerMapper.trip(train, serviceDate: now, stations: [:], now: now)
}

@Test func amtrakerEmptyPlatformIsMissingFromFeedNotUnassigned() throws {
    let boarding = try #require(try washingtonTrain(platform: "").stopTimes.first)

    #expect(boarding.plannedPlatform == nil)
    #expect(boarding.expectedPlatform == nil)
    #expect(boarding.platformGuidance() == .unavailable)
    #expect(boarding.platformKind == .track)
    #expect(boarding.platformNoun == "Track")
    #expect(boarding.platformSummary() == "Track not in live feed · Check station boards")
    #expect(PlatformGuidance.unavailable.metricValue == "Not in feed")
}

@Test func amtrakerReportedValueIsATrackCreditedToAmtraker() throws {
    let boarding = try #require(try washingtonTrain(platform: "17").stopTimes.first)

    #expect(boarding.displayPlatform == "17")
    #expect(boarding.platformSummary() == "Track 17 · via Amtraker")
    // A gate is a different place; the model never stores or invents one.
    #expect(!boarding.platformSummary().localizedCaseInsensitiveContains("gate"))
}

@Test func stopTimeDecodesWhenAnOlderArchiveHasNoPlatformKindOrSource() throws {
    let stop = try #require(try washingtonTrain(platform: "17").stopTimes.first)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stop)) as? [String: Any])
    object.removeValue(forKey: "platformKind")
    object.removeValue(forKey: "platformSource")

    let decoded = try JSONDecoder().decode(StopTime.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.platformKind == nil)
    #expect(decoded.platformNoun == "Platform")
    #expect(decoded.platformSummary() == "Platform 17 · operator confirmed")
}

private func amtrakTrip(id: String, source: String, operatorName: String, kind: PlatformKind?) -> TrainTrip {
    let station = Station(
        id: RailIdentifier(rawValue: "test:WIL"), names: [LocalizedStationName("Wilmington")],
        location: GeoCoordinate(latitude: 39.74, longitude: -75.55), countryCode: "US"
    )
    return TrainTrip(
        id: RailIdentifier(rawValue: id), source: source, serviceDate: Date(timeIntervalSince1970: 1_792_000_000),
        operatorName: operatorName, product: "Northeast Regional 171", headsign: "Washington",
        stopTimes: [StopTime(station: station, sequence: 1, plannedPlatform: "2", platformKind: kind)],
        capabilities: RealtimeCapabilities(
            hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop
        )
    )
}

@Test func amtrakTrainsFromOtherFeedsAndOldSavesReadAsTracks() throws {
    let viaTransitous = amtrakTrip(
        id: "eu:transitous:20261025_06:20_us-Amtrak_296943", source: "transitous", operatorName: "", kind: .platform
    )
    #expect(viaTransitous.stopTimes.first?.platformNoun == "Track")

    let unlabelled = amtrakTrip(id: "us:amtraker:171-24", source: "amtraker", operatorName: "Amtrak", kind: nil)
    #expect(unlabelled.stopTimes.first?.platformNoun == "Track")

    // A trip saved before platform kinds existed decodes into the same rule.
    let saved = try JSONDecoder().decode(TrainTrip.self, from: JSONEncoder().encode(unlabelled))
    #expect(saved.stopTimes.first?.platformKind == .track)
}

@Test func nonAmtrakTrainsKeepPlatforms() {
    let ice = amtrakTrip(id: "eu:transitous:ice-946", source: "transitous", operatorName: "DB Fernverkehr", kind: .platform)
    #expect(ice.stopTimes.first?.platformNoun == "Platform")
}
