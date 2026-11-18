import Foundation
import Testing
@testable import TrainTrackerCore

private let station = Station(
    id: RailIdentifier(rawValue: "eu:transitous:berlin-hbf"),
    names: [LocalizedStationName("Berlin Hbf")],
    location: GeoCoordinate(latitude: 52.525, longitude: 13.369),
    countryCode: "DE"
)

private func forecast(
    state: PlatformForecast.State = .positioning,
    likelyPlatform: String? = nil,
    expiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000)
) -> PlatformForecast {
    PlatformForecast(
        state: state,
        zone: PlatformForecast.Zone(
            id: "east",
            label: "east concourse",
            platforms: ["8", "9"],
            probability: 0.93
        ),
        candidates: [
            PlatformForecast.Candidate(platform: "8", probability: 0.87, observationCount: 27),
            PlatformForecast.Candidate(platform: "9", probability: 0.13, observationCount: 3),
        ],
        likelyPlatform: likelyPlatform,
        confidence: .high,
        evidenceCount: 30,
        explanation: "30 completed comparable services in 2025-2026.",
        horizon: .oneHourToSixHours,
        modelVersion: "historical-bayes-v1",
        timetablePeriod: "2025-2026",
        stationMapVersion: "berlin-map-v1",
        generatedAt: Date(timeIntervalSince1970: 1_999_998_200),
        expiresAt: expiresAt
    )
}

private func stop(
    plannedPlatform: String? = nil,
    expectedPlatform: String? = nil,
    platformForecast: PlatformForecast? = forecast()
) -> StopTime {
    StopTime(
        station: station,
        sequence: 1,
        scheduledDeparture: Date(timeIntervalSince1970: 2_000_010_000),
        plannedPlatform: plannedPlatform,
        expectedPlatform: expectedPlatform,
        platformForecast: platformForecast
    )
}

@Test func positioningForecastProducesExplicitPredictionGuidance() {
    let guidance = stop().platformGuidance(at: Date(timeIntervalSince1970: 1_999_999_000))

    #expect(guidance == .positioning(
        zoneLabel: "east concourse",
        platforms: ["8", "9"],
        confidence: .high,
        explanation: "30 completed comparable services in 2025-2026."
    ))
    #expect(guidance.summaryText == "Wait near the east concourse · likely platforms 8–9")
    #expect(guidance.metricValue == "East concourse")
    #expect(guidance.accessibilityText.contains("Roundhouse prediction"))
}

@Test func exactForecastRemainsVisiblyLikelyRatherThanOfficial() {
    let guidance = stop(platformForecast: forecast(
        state: .likelyPlatform,
        likelyPlatform: "8"
    )).platformGuidance(at: Date(timeIntervalSince1970: 1_999_999_000))

    #expect(guidance.summaryText == "Likely platform 8 · prediction")
    #expect(guidance.metricValue == "Likely 8")
    #expect(guidance.isPredicted)
}

@Test func officialExpectedAndPlannedPlatformsOverrideForecast() {
    let current = stop(plannedPlatform: "8", expectedPlatform: "10")
        .platformGuidance(at: Date(timeIntervalSince1970: 1_999_999_000))
    let scheduled = stop(plannedPlatform: "8")
        .platformGuidance(at: Date(timeIntervalSince1970: 1_999_999_000))

    #expect(current == .official(platform: "10", source: .current, changed: true))
    #expect(current.summaryText == "Platform changed to 10 · operator confirmed")
    #expect(!current.isPredicted)
    #expect(scheduled == .official(platform: "8", source: .scheduled, changed: false))
    #expect(scheduled.summaryText == "Scheduled platform 8 · operator timetable")
}

@Test func expiredForecastResolvesToUnavailable() {
    let guidance = stop(platformForecast: forecast(
        expiresAt: Date(timeIntervalSince1970: 1_999_999_000)
    )).platformGuidance(at: Date(timeIntervalSince1970: 1_999_999_000))

    #expect(guidance == .unavailable)
    #expect(guidance.summaryText == "Platform not in live feed · Check station boards")
}

@Test func stopTimeDecodesWhenAnOlderArchiveHasNoForecastKey() throws {
    let encoded = try JSONEncoder().encode(stop(platformForecast: nil))
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "platformForecast")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(StopTime.self, from: legacyData)

    #expect(decoded.platformForecast == nil)
    #expect(decoded.displayPlatform == nil)
}
