#if DEBUG
import Foundation
import SwiftUI
import TrainTrackerCore

enum JourneyPreviewHorizontalSizeClass: Equatable {
    case compact

    static func resolve(arguments: [String]) -> Self? {
        arguments.contains("-JourneyPreviewCompactWidth") ? .compact : nil
    }

    var value: UserInterfaceSizeClass { .compact }
}

enum JourneyPreviewViewport: Equatable {
    case narrow

    static func resolve(arguments: [String]) -> Self? {
        arguments.contains("-JourneyPreviewCompactWidth") ? .narrow : nil
    }

    var contentMaxWidth: CGFloat { 480 }
}

struct JourneyJapanesePreviewFixture {
    let form: JourneySearchFormState
    let outboundPage: JourneySearchPage

    init() {
        let shinHakodate = Self.place(
            id: "preview:shin-hakodate-hokuto",
            name: "新函館北斗駅（北海道新幹線・函館本線）",
            context: "北海道北斗市",
            timeZone: "Asia/Tokyo",
            latitude: 41.9048,
            longitude: 140.6487
        )
        let tokyo = Self.place(
            id: "preview:tokyo",
            name: "東京駅（東北・上越・北陸・北海道新幹線）",
            context: "東京都千代田区",
            timeZone: "Asia/Tokyo",
            latitude: 35.6812,
            longitude: 139.7671
        )
        let start = Self.date("2026-07-24T21:35:00Z")
        let end = Self.date("2026-07-25T02:04:00Z")
        let rail = RailJourneySegment(
            id: "preview-japanese-hayabusa",
            tripID: RailIdentifier(rawValue: "preview:trip:japanese-hayabusa"),
            serviceDate: start,
            operatorName: "北海道旅客鉄道株式会社・東日本旅客鉄道株式会社",
            product: "東北・北海道新幹線",
            trainNumber: "はやぶさ18号",
            trainName: "新幹線はやぶさ18号",
            from: JourneyCall(
                place: shinHakodate,
                city: nil,
                scheduledArrival: nil,
                scheduledDeparture: start,
                expectedArrival: nil,
                expectedDeparture: Self.date("2026-07-24T21:38:00Z"),
                plannedPlatform: "11",
                expectedPlatform: "12",
                isCancelled: false
            ),
            to: JourneyCall(
                place: tokyo,
                city: nil,
                scheduledArrival: end,
                scheduledDeparture: nil,
                expectedArrival: Self.date("2026-07-25T02:07:00Z"),
                expectedDeparture: nil,
                plannedPlatform: "22",
                expectedPlatform: "22",
                isCancelled: false
            ),
            intermediateCalls: [],
            isCancelled: false,
            isRealtime: true,
            isTrackable: true,
            untrackableReason: nil
        )
        let option = JourneyOption(
            id: "preview-japanese-direct",
            fingerprint: "preview-fingerprint-japanese-direct",
            startTime: start,
            endTime: end,
            duration: end.timeIntervalSince(start),
            transferCount: 0,
            segments: [.rail(rail)],
            badges: [.direct, .fastest, .fewestChanges],
            trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 1),
            realtimeFreshness: Self.date("2026-07-22T15:00:00Z"),
            attributions: ["Transitous", "OpenStreetMap contributors"],
            trackingToken: "preview.signed.japanese-direct"
        )

        form = JourneySearchFormState(
            origin: shinHakodate,
            destination: tokyo,
            outboundTime: start,
            returnEnabled: false,
            maximumTransfers: 4
        )
        outboundPage = JourneySearchPage(
            generatedAt: Self.date("2026-07-22T15:00:00Z"),
            expiresAt: Self.date("2026-07-22T15:10:00Z"),
            options: [option],
            previousCursor: "preview.japanese.previous.signed",
            nextCursor: "preview.japanese.next.signed",
            warnings: [],
            attributions: ["Transitous", "OpenStreetMap contributors"]
        )
    }

    private static func place(
        id: String,
        name: String,
        context: String,
        timeZone: String,
        latitude: Double,
        longitude: Double
    ) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: id),
            kind: .station,
            displayName: name,
            context: context,
            countryCode: "JP",
            timeZoneIdentifier: timeZone,
            location: GeoCoordinate(latitude: latitude, longitude: longitude),
            eligibleModes: ["highSpeedRail", "longDistanceRail"],
            attributions: ["Transitous", "OpenStreetMap contributors"]
        )
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

actor JourneyJapanesePreviewClient: JourneySearching {
    private let fixture: JourneyJapanesePreviewFixture

    init(fixture: JourneyJapanesePreviewFixture) {
        self.fixture = fixture
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
        [fixture.form.origin, fixture.form.destination].compactMap { $0 }
    }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        fixture.outboundPage
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        JourneyPlanResolution(directions: [])
    }
}
#endif
