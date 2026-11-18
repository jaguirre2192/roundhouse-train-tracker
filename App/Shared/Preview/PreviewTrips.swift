import Foundation
import TrainTrackerCore

enum PreviewTrips {
    static func make(referenceDate: Date) -> [TrainTrip] {
        [activeNortheastRegional(referenceDate), upcomingBrightline(referenceDate)]
    }

    private static func activeNortheastRegional(_ now: Date) -> TrainTrip {
        let newYork = station(
            region: "us",
            nativeID: "NYP",
            name: "New York Penn",
            latitude: 40.7506,
            longitude: -73.9935
        )
        let philadelphia = station(
            region: "us",
            nativeID: "PHL",
            name: "Philadelphia 30th Street",
            latitude: 39.9556,
            longitude: -75.1820
        )
        let wilmington = station(
            region: "us",
            nativeID: "WIL",
            name: "Wilmington",
            latitude: 39.7368,
            longitude: -75.5517
        )
        let baltimore = station(
            region: "us",
            nativeID: "BAL",
            name: "Baltimore Penn",
            latitude: 39.3074,
            longitude: -76.6156
        )
        let washington = station(
            region: "us",
            nativeID: "WAS",
            name: "Washington Union",
            latitude: 38.8971,
            longitude: -77.0064
        )

        return TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: "171:today"),
            source: "amtraker",
            serviceDate: now,
            operatorName: "Amtrak",
            product: "Northeast Regional 171",
            headsign: "Washington",
            stopTimes: [
                stop(newYork, sequence: 1, minutesFromNow: -128, delay: 4, platform: "9", passed: true, now: now),
                stop(philadelphia, sequence: 2, minutesFromNow: -38, delay: 6, platform: "4", passed: true, now: now),
                stop(wilmington, sequence: 3, minutesFromNow: 4, delay: 7, platform: "2", passed: false, now: now),
                stop(baltimore, sequence: 4, minutesFromNow: 48, delay: 7, platform: "6", passed: false, now: now),
                stop(washington, sequence: 5, minutesFromNow: 88, delay: 6, platform: "A", passed: false, now: now),
            ],
            // `-AppStorePreviewTrack` gives the preview train a track line, so the map can carry
            // it between reports the way it carries a live Amtrak train.
            routeGeometry: ProcessInfo.processInfo.arguments.contains("-AppStorePreviewTrack") ? northeastCorridorTrack : nil,
            positions: [
                VehiclePosition(
                    coordinate: GeoCoordinate(latitude: 39.84, longitude: -75.33),
                    heading: 224,
                    source: .real,
                    confidence: 0.98,
                    asOf: now.addingTimeInterval(-42)
                ),
            ],
            alerts: [
                RailAlert(
                    id: RailIdentifier(region: "us", source: "amtraker", nativeID: "alert-171"),
                    severity: .minor,
                    cause: "Congestion",
                    affectedTripIDs: [RailIdentifier(region: "us", source: "amtraker", nativeID: "171:today")],
                    message: "Signal congestion south of Philadelphia is adding about 7 minutes."
                ),
            ],
            capabilities: RealtimeCapabilities(
                hasPositions: true,
                hasPlatforms: true,
                hasRealtimeDelays: true,
                hasAlerts: true,
                granularity: .perStop
            )
        )
    }

    /// An approximate Northeast Corridor line through the preview train's stops and position.
    private static var northeastCorridorTrack: RouteGeometry {
        let points: [(Double, Double)] = [
            (40.7506, -73.9935), (40.7613, -74.0758), (40.7347, -74.1644), (40.6677, -74.2153), (40.6063, -74.2767),
            (40.5681, -74.3296), (40.4971, -74.4459), (40.3164, -74.6238), (40.2187, -74.7550), (40.0717, -74.9522),
            (39.9973, -75.1551), (39.9556, -75.1820), (39.9050, -75.2450), (39.8400, -75.3300), (39.7977, -75.4530),
            (39.7368, -75.5517), (39.6699, -75.7533), (39.6068, -75.8333), (39.5579, -76.0736), (39.5085, -76.1630),
            (39.4190, -76.2890), (39.3320, -76.4210), (39.3074, -76.6156), (39.1923, -76.6946), (39.0862, -76.7063),
            (39.0070, -76.7790), (38.9480, -76.8720), (38.8971, -77.0064),
        ]
        // The standard encoded polyline, five decimal places.
        func encode(_ value: Int) -> String {
            var remaining = value < 0 ? ~(value << 1) : value << 1
            var text = ""
            while remaining >= 0x20 {
                text.append(Character(UnicodeScalar(UInt8((0x20 | (remaining & 0x1f)) + 63))))
                remaining >>= 5
            }
            text.append(Character(UnicodeScalar(UInt8(remaining + 63))))
            return text
        }
        var encoded = "", lastLatitude = 0, lastLongitude = 0
        for (latitude, longitude) in points {
            let lat = Int((latitude * 1e5).rounded()), lon = Int((longitude * 1e5).rounded())
            encoded += encode(lat - lastLatitude) + encode(lon - lastLongitude)
            lastLatitude = lat
            lastLongitude = lon
        }
        return RouteGeometry(source: "Preview", segments: [
            RouteGeometry.Segment(encodedPolyline: encoded, precision: 5, pointCount: points.count),
        ])
    }

    private static func upcomingBrightline(_ now: Date) -> TrainTrip {
        let orlando = station(
            region: "us",
            nativeID: "ORL",
            name: "Orlando",
            latitude: 28.4179,
            longitude: -81.2910
        )
        let westPalm = station(
            region: "us",
            nativeID: "WPB",
            name: "West Palm Beach",
            latitude: 26.7132,
            longitude: -80.0552
        )
        let miami = station(
            region: "us",
            nativeID: "MIA",
            name: "MiamiCentral",
            latitude: 25.7797,
            longitude: -80.1957
        )

        return TrainTrip(
            id: RailIdentifier(region: "us", source: "amtraker", nativeID: "bl-103:tomorrow"),
            source: "amtraker",
            serviceDate: now.addingTimeInterval(24 * 60 * 60),
            operatorName: "Brightline",
            product: "Brightline 103",
            headsign: "MiamiCentral",
            stopTimes: [
                stop(orlando, sequence: 1, minutesFromNow: 24 * 60 + 75, delay: 0, platform: nil, passed: false, now: now),
                stop(westPalm, sequence: 2, minutesFromNow: 24 * 60 + 210, delay: 0, platform: nil, passed: false, now: now),
                stop(miami, sequence: 3, minutesFromNow: 24 * 60 + 282, delay: 0, platform: nil, passed: false, now: now),
            ],
            capabilities: RealtimeCapabilities(
                hasPositions: true,
                hasPlatforms: false,
                hasRealtimeDelays: true,
                hasAlerts: true,
                granularity: .perStop
            )
        )
    }

    private static func station(
        region: String,
        nativeID: String,
        name: String,
        latitude: Double,
        longitude: Double
    ) -> Station {
        Station(
            id: RailIdentifier(region: region, source: "gazetteer", nativeID: nativeID),
            names: [LocalizedStationName(name, localeIdentifier: "en_US")],
            codes: [.sourceNative: nativeID],
            location: GeoCoordinate(latitude: latitude, longitude: longitude),
            countryCode: "US"
        )
    }

    private static func stop(
        _ station: Station,
        sequence: Int,
        minutesFromNow: Int,
        delay: Int,
        platform: String?,
        passed: Bool,
        now: Date
    ) -> StopTime {
        let scheduled = now.addingTimeInterval(TimeInterval(minutesFromNow * 60))
        let expected = scheduled.addingTimeInterval(TimeInterval(delay * 60))
        return StopTime(
            station: station,
            sequence: sequence,
            scheduledArrival: sequence == 1 ? nil : scheduled,
            scheduledDeparture: scheduled,
            expectedArrival: sequence == 1 ? nil : expected,
            expectedDeparture: expected,
            plannedPlatform: platform,
            expectedPlatform: platform,
            isPassed: passed
        )
    }
}
