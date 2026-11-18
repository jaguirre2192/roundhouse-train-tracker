#if DEBUG
import Foundation
import TrainTrackerCore
import UIKit

/// Deterministic, isolated fixture for native intake QA (`-FrictionlessIntakeQA`). It never reads
/// or writes the person's saved tickets, journeys or trains, and sends no network requests.
enum FrictionlessIntakeQA {
    static func isEnabled(arguments: [String]) -> Bool {
        arguments.contains("-FrictionlessIntakeQA")
    }

    /// `-FrictionlessIntakeQAFailSearch` makes the first journey search fail, to exercise retry.
    static func searchFailures(arguments: [String]) -> Int {
        arguments.contains("-FrictionlessIntakeQAFailSearch") ? 1 : 0
    }

    static func documentFixturesEnabled(arguments: [String]) -> Bool {
        isEnabled(arguments: arguments) && arguments.contains("-FrictionlessIntakeQADocumentFixtures")
    }

    @MainActor
    static func ticketImageData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 1_600))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_600))
            let lines = [
                "AMTRAK",
                "ACELA 2150",
                "Boston South Station to New York Penn Station",
                "Travel date: \(futureDay())",
                "Departs 8:05 AM",
                "Coach 5  Seat 14A",
            ]
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .semibold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
            let text = lines.joined(separator: "\n\n") as NSString
            text.draw(
                in: CGRect(x: 70, y: 180, width: 1_060, height: 1_200),
                withAttributes: attributes
            )
        }.pngData() ?? Data()
    }

    @MainActor
    static func ticketPDFData() -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            let lines = [
                "AMTRAK",
                "ACELA 2150",
                "Boston South Station to New York Penn Station",
                "Travel date: \(futureDay())",
                "Departs 8:05 AM",
                "Coach 5 Seat 14A",
            ]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: UIColor.black,
            ]
            (lines.joined(separator: "\n\n") as NSString).draw(
                in: CGRect(x: 54, y: 80, width: 504, height: 620),
                withAttributes: attributes
            )
        }
    }

    private static func futureDay() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: 7, to: .now)!)
    }

    static func vaultDirectory(arguments: [String]) -> URL {
        let directory = URL.temporaryDirectory.appending(path: "FrictionlessIntakeQA", directoryHint: .isDirectory)
        if arguments.contains("-FrictionlessIntakeQAReset") {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    static let origin = place(id: "qa:boston-south", name: "Boston South Station", latitude: 42.3523, longitude: -71.0552)
    static let destination = place(id: "qa:new-york-penn", name: "New York Penn Station", latitude: 40.7506, longitude: -73.9935)

    private static func place(id: String, name: String, latitude: Double, longitude: Double) -> RailPlace {
        RailPlace(
            id: RailIdentifier(rawValue: id), kind: .station, displayName: name, context: "United States",
            countryCode: "US", timeZoneIdentifier: "America/New_York",
            location: GeoCoordinate(latitude: latitude, longitude: longitude),
            eligibleModes: ["longDistanceRail"], attributions: ["QA fixture"]
        )
    }
}

/// Returns the requested departure (train 2150) and a later train (2154) for the fixture route.
actor FrictionlessIntakeQAClient: JourneySearching {
    private var failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] {
        let key = ImportedStationMatcher.key(query)
        return [FrictionlessIntakeQA.origin, FrictionlessIntakeQA.destination].filter {
            ImportedStationMatcher.key($0.displayName).contains(key) || key.contains(ImportedStationMatcher.key($0.displayName))
        }
    }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        try await Task.sleep(for: .milliseconds(400))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw URLError(.notConnectedToInternet)
        }
        let start = criteria.requestedTime
        let options = [
            Self.option(number: "2150", start: start),
            Self.option(number: "2154", start: start.addingTimeInterval(3_600)),
        ]
        return JourneySearchPage(
            generatedAt: .now, expiresAt: .now.addingTimeInterval(600), options: options,
            previousCursor: nil, nextCursor: nil, warnings: [], attributions: ["QA fixture"]
        )
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        let directions = trackingTokens.compactMap { token -> JourneyPlanResolution.Direction? in
            let parts = token.split(separator: "|")
            guard parts.count == 3, let interval = TimeInterval(parts[2]) else { return nil }
            let number = String(parts[1])
            let start = Date(timeIntervalSince1970: interval)
            let end = start.addingTimeInterval(4 * 3_600)
            let trip = Self.trip(number: number, start: start, end: end)
            return JourneyPlanResolution.Direction(
                fingerprint: "qa-\(number)-\(Int(interval))",
                originStationID: FrictionlessIntakeQA.origin.id,
                destinationStationID: FrictionlessIntakeQA.destination.id,
                departure: start, arrival: end,
                segments: [JourneyPlanResolution.Segment(segmentID: "qa-rail-\(number)", trip: trip, failure: nil)]
            )
        }
        return JourneyPlanResolution(directions: directions)
    }

    private static func option(number: String, start: Date) -> JourneyOption {
        let end = start.addingTimeInterval(4 * 3_600)
        let rail = RailJourneySegment(
            id: "qa-rail-\(number)", tripID: RailIdentifier(rawValue: "qa:trip:\(number)"), serviceDate: start,
            operatorName: "Amtrak", product: "Acela", trainNumber: number, trainName: "Acela \(number)",
            from: JourneyCall(place: FrictionlessIntakeQA.origin, city: nil, scheduledArrival: nil, scheduledDeparture: start,
                              expectedArrival: nil, expectedDeparture: nil, plannedPlatform: nil, expectedPlatform: nil, isCancelled: false),
            to: JourneyCall(place: FrictionlessIntakeQA.destination, city: nil, scheduledArrival: end, scheduledDeparture: nil,
                            expectedArrival: nil, expectedDeparture: nil, plannedPlatform: nil, expectedPlatform: nil, isCancelled: false),
            intermediateCalls: [], isCancelled: false, isRealtime: false, isTrackable: true, untrackableReason: nil
        )
        return JourneyOption(
            id: "qa-\(number)", fingerprint: "qa-\(number)-\(Int(start.timeIntervalSince1970))",
            startTime: start, endTime: end, duration: end.timeIntervalSince(start), transferCount: 0,
            segments: [.rail(rail)], badges: [.direct], trackability: JourneyTrackability(trackableRailSegments: 1, totalRailSegments: 1),
            realtimeFreshness: nil, attributions: ["QA fixture"],
            trackingToken: "qa|\(number)|\(Int(start.timeIntervalSince1970))"
        )
    }

    private static func trip(number: String, start: Date, end: Date) -> TrainTrip {
        func stop(_ place: RailPlace, sequence: Int, arrival: Date?, departure: Date?) -> StopTime {
            StopTime(
                station: Station(id: place.id, names: [LocalizedStationName(place.displayName)], location: place.location, countryCode: "US"),
                sequence: sequence, scheduledArrival: arrival, scheduledDeparture: departure
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "qa:trip:\(number)"), source: "qa", serviceDate: start, operatorName: "Amtrak",
            product: "Acela \(number)", headsign: "New York",
            stopTimes: [
                stop(FrictionlessIntakeQA.origin, sequence: 1, arrival: nil, departure: start),
                stop(FrictionlessIntakeQA.destination, sequence: 2, arrival: end, departure: nil),
            ],
            capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop)
        )
    }
}
#endif
