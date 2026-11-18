import Foundation
import Testing
@testable import TrainTrackerCore

/// Train 2120 on September 15, 2026: saved from journey search with a Transitous identity, the
/// map showed "Position unavailable" while Amtraker reported GPS near BWI at 5:26 PM Eastern.
private func instance(_ id: String, departure: String, lat: Double? = 39.176010356179454,
                      lon: Double? = -76.69444495410441, lastValTS: String? = "2026-09-15T17:25:41-04:00") throws -> AmtrakerTrainDTO {
    let latText = lat.map { "\($0)" } ?? "null"
    let lonText = lon.map { "\($0)" } ?? "null"
    let lastText = lastValTS.map { "\"\($0)\"" } ?? "null"
    return try JSONDecoder().decode(AmtrakerTrainDTO.self, from: Data("""
    {"trainID":"\(id)","trainNum":"2120","routeName":"Acela","lat":\(latText),"lon":\(lonText),
     "updatedAt":"2026-09-15T17:26:31-04:00","lastValTS":\(lastText),"trainState":"Active",
     "stations":[{"name":"Washington Union","code":"WAS","schDep":"\(departure)","dep":"\(departure)","status":"Departed","platform":""}]}
    """.utf8))
}

private func transitousTrip(departure: String) throws -> TrainTrip {
    let date = try #require(RailDateParser.parse(departure))
    return TrainTrip(
        id: RailIdentifier(rawValue: "us:transitous:20_us-Amtrak_285229"), source: "transitous", serviceDate: date,
        operatorName: "Amtrak", product: "2120", headsign: "Ny Moynihan Train Hall At Penn Station",
        stopTimes: [StopTime(
            station: Station(id: RailIdentifier(rawValue: "us:transitous:us-Amtrak_WAS"),
                             names: [LocalizedStationName("Washington Union Station")],
                             location: GeoCoordinate(latitude: 38.897, longitude: -77.006), countryCode: "US"),
            sequence: 1, scheduledDeparture: date
        )],
        capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
    )
}

@Test func journeySearchAmtrakTripGetsTheSameDaysAmtrakerPosition() throws {
    let trip = try transitousTrip(departure: "2026-09-15T17:05:00-04:00")
    let now = try #require(RailDateParser.parse("2026-09-15T17:28:00-04:00"))
    let today = try instance("2120-15", departure: "2026-09-15T17:05:00-04:00")
    let yesterday = try instance("2120-14", departure: "2026-09-14T17:05:00-04:00", lat: 40.0, lon: -75.0)

    #expect(AmtrakPositionMatcher.isAmtrak(trip))
    #expect(AmtrakPositionMatcher.trainNumber(for: trip) == "2120")
    let position = try #require(AmtrakPositionMatcher.position(for: trip, in: [yesterday, today], now: now))
    #expect(position.coordinate.latitude == 39.176010356179454)
    #expect(position.coordinate.longitude == -76.69444495410441)
    #expect(position.source == .real)
    #expect(position.asOf == RailDateParser.parse("2026-09-15T17:25:41-04:00"))
}

@Test func ambiguousMissingOrStaleAmtrakerPositionsAreNotAttached() throws {
    let trip = try transitousTrip(departure: "2026-09-15T17:05:00-04:00")
    let now = try #require(RailDateParser.parse("2026-09-15T17:28:00-04:00"))
    let duplicate = try instance("2120-15", departure: "2026-09-15T17:05:00-04:00")
    let twin = try instance("2120-15b", departure: "2026-09-15T17:05:30-04:00")
    #expect(AmtrakPositionMatcher.position(for: trip, in: [duplicate, twin], now: now) == nil, "Ambiguous instance")

    let noGPS = try instance("2120-15", departure: "2026-09-15T17:05:00-04:00", lat: nil, lon: nil)
    #expect(AmtrakPositionMatcher.position(for: trip, in: [noGPS], now: now) == nil)

    let old = try instance("2120-15", departure: "2026-09-15T17:05:00-04:00", lastValTS: "2026-09-15T15:00:00-04:00")
    #expect(AmtrakPositionMatcher.position(for: trip, in: [old], now: now) == nil, "Hours-old GPS is not attached")

    let otherDay = try instance("2120-16", departure: "2026-09-16T17:05:00-04:00")
    #expect(AmtrakPositionMatcher.position(for: trip, in: [otherDay], now: now) == nil, "Another day's 2120")
}

private func amtrakerTrip(nativeID: String, departure: String) throws -> TrainTrip {
    let date = try #require(RailDateParser.parse(departure))
    return TrainTrip(
        id: RailIdentifier(region: "us", source: "amtraker", nativeID: nativeID), source: "amtraker",
        serviceDate: date, operatorName: "Amtrak", product: "Acela 2120", headsign: "New York",
        stopTimes: [StopTime(
            station: Station(id: RailIdentifier(rawValue: "us:amtraker:WAS"), names: [LocalizedStationName("Washington Union")],
                             codes: [.sourceNative: "WAS"], location: GeoCoordinate(latitude: 38.897, longitude: -77.006), countryCode: "US"),
            sequence: 1, scheduledDeparture: date
        )],
        capabilities: AmtrakerMapper.capabilities
    )
}

@Test func amtrakerIdentityUsesItsExactInstanceOnlyWithScheduleCorroboration() throws {
    let trip = try amtrakerTrip(nativeID: "2120-15", departure: "2026-09-15T17:05:00-04:00")
    let exact = try instance("2120-15", departure: "2026-09-15T17:05:00-04:00")
    let other = try instance("2120-14", departure: "2026-09-14T17:05:00-04:00", lat: 40, lon: -75)
    #expect(AmtrakPositionMatcher.trainNumber(for: trip) == "2120")
    #expect(AmtrakPositionMatcher.matchingTrain(for: trip, in: [other, exact])?.trainID == "2120-15")
}

@Test func staleSavedTripDoesNotMatchNextMonthsSameDayOfMonthInstance() throws {
    // "2120-15" recurs on the 15th of every month; a trip saved for August must not take
    // September's GPS just because the ID is identical.
    let augustTrip = try amtrakerTrip(nativeID: "2120-15", departure: "2026-08-15T17:05:00-04:00")
    let september = try instance("2120-15", departure: "2026-09-15T17:05:00-04:00")
    let now = try #require(RailDateParser.parse("2026-09-15T17:28:00-04:00"))
    #expect(AmtrakPositionMatcher.matchingTrain(for: augustTrip, in: [september]) == nil)
    #expect(AmtrakPositionMatcher.position(for: augustTrip, in: [september], now: now) == nil)
}

@Test func sameTimeAtAnUnrelatedStationIsNotAMatch() throws {
    // A candidate calling somewhere else at 17:05 must not match a train departing WAS at 17:05.
    let trip = try transitousTrip(departure: "2026-09-15T17:05:00-04:00")
    let elsewhere = try JSONDecoder().decode(AmtrakerTrainDTO.self, from: Data("""
    {"trainID":"2120-15","trainNum":"2120","routeName":"Acela","lat":39.2,"lon":-76.7,
     "lastValTS":"2026-09-15T17:25:41-04:00",
     "stations":[{"name":"Philadelphia 30th Street","code":"PHL","schDep":"2026-09-15T17:05:00-04:00"}]}
    """.utf8))
    #expect(AmtrakPositionMatcher.matchingTrain(for: trip, in: [elsewhere]) == nil)
    #expect(AmtrakPositionMatcher.amtrakCode(for: trip.stopTimes[0].station) == "WAS")
}

@Test func undatedMalformedFutureOrInvalidGPSIsRejected() throws {
    let now = try #require(RailDateParser.parse("2026-09-15T17:28:00-04:00"))
    func dto(lat: String, lon: String, lastValTS: String?, updatedAt: String?) throws -> AmtrakerTrainDTO {
        let last = lastValTS.map { "\"\($0)\"" } ?? "null"
        let updated = updatedAt.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(AmtrakerTrainDTO.self, from: Data("""
        {"trainID":"2120-15","trainNum":"2120","routeName":"Acela","lat":\(lat),"lon":\(lon),
         "lastValTS":\(last),"updatedAt":\(updated),"stations":[]}
        """.utf8))
    }
    #expect(AmtrakerMapper.position(try dto(lat: "39.17", lon: "-76.69", lastValTS: nil, updatedAt: nil), now: now) == nil,
            "Undated GPS has unknown age and is never shown as fresh")
    #expect(AmtrakerMapper.position(try dto(lat: "39.17", lon: "-76.69", lastValTS: "yesterday-ish", updatedAt: "??"), now: now) == nil)
    #expect(AmtrakerMapper.position(try dto(lat: "39.17", lon: "-76.69", lastValTS: "2026-09-15T18:30:00-04:00", updatedAt: nil), now: now) == nil,
            "An hour in the future is implausible")
    #expect(AmtrakerMapper.position(try dto(lat: "91", lon: "-76.69", lastValTS: "2026-09-15T17:25:41-04:00", updatedAt: nil), now: now) == nil)
    #expect(AmtrakerMapper.position(try dto(lat: "39.17", lon: "-181", lastValTS: "2026-09-15T17:25:41-04:00", updatedAt: nil), now: now) == nil)
    #expect(AmtrakerMapper.position(try dto(lat: "0", lon: "0", lastValTS: "2026-09-15T17:25:41-04:00", updatedAt: nil), now: now) == nil)
    let valid = try #require(AmtrakerMapper.position(try dto(lat: "39.17", lon: "-76.69", lastValTS: nil, updatedAt: "2026-09-15T17:27:30-04:00"), now: now))
    #expect(valid.asOf == RailDateParser.parse("2026-09-15T17:27:30-04:00"), "A valid updatedAt stands in for a missing lastValTS")
}
