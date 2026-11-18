#if DEBUG
import Foundation
import TrainTrackerCore

enum JourneyExperienceScenario: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming"
    case departure = "Departure soon"
    case underway = "Underway"
    case connection = "Connection"
    case delayed = "Disrupted"
    case ended = "Ended"
    case cancelled = "Cancelled"
    case scheduled = "Schedule only"

    var id: String { rawValue }
}

struct JourneyExperiencePreviewData {
    let trips: [TrainTrip]
    let plan: TrackedJourneyPlan
    let referenceDate: Date

    static func make(_ scenario: JourneyExperienceScenario) -> Self {
        let departure = ISO8601DateFormatter().date(from: "2026-09-15T20:20:00Z")!
        let stations = [
            station("WAS", "Washington Union Station", 38.897, -77.006),
            station("BAL", "Baltimore Penn Station", 39.307, -76.615),
            station("PHL", "Philadelphia 30th Street", 39.956, -75.182),
            station("NYP", "New York Penn Station", 40.750, -73.993),
            station("BOS", "Boston South Station", 42.352, -71.055)
        ]
        let offsets: [TimeInterval] = [0, 35, 105, 180, 410].map { $0 * 60 }
        let usesEstimates = scenario != .scheduled && scenario != .upcoming
        let delay: TimeInterval = scenario == .delayed ? 20 * 60 : 0
        let trip = TrainTrip(
            id: RailIdentifier(rawValue: "us:amtrak:experience-acela"),
            source: "amtraker", serviceDate: departure,
            operatorName: "Amtrak", product: "Acela 2162", headsign: "Boston",
            stopTimes: zip(stations, offsets).enumerated().map { index, pair in
                let date = departure.addingTimeInterval(pair.1)
                return StopTime(
                    station: pair.0, sequence: index,
                    scheduledArrival: index == 0 ? nil : date,
                    scheduledDeparture: index == stations.count - 1 ? nil : date,
                    expectedArrival: usesEstimates && index > 0 ? date.addingTimeInterval(delay) : nil,
                    expectedDeparture: usesEstimates && index < stations.count - 1 ? date.addingTimeInterval(delay) : nil,
                    plannedPlatform: ["16", "2", "5", "8", "7"][index],
                    expectedPlatform: scenario == .delayed && index == 0 ? "18" : nil,
                    isCancelled: scenario == .cancelled
                )
            },
            alerts: scenario == .delayed ? [RailAlert(
                id: RailIdentifier(rawValue: "preview:delay"), severity: .major,
                cause: "Departure update", message: "This service is running approximately 20 minutes late. Check the station display before boarding.",
                validFrom: departure.addingTimeInterval(-3600), validUntil: departure.addingTimeInterval(3600)
            )] : [],
            capabilities: capabilities
        )
        let firstSegment = JourneyPlanSegment(
            id: "preview-selected-acela", kind: .rail,
            from: place(stations[0]), to: place(stations[3]),
            departure: departure, arrival: departure.addingTimeInterval(180 * 60),
            serviceName: trip.product, resolvedTripID: trip.id
        )
        let secondDeparture = departure.addingTimeInterval(205 * 60)
        let second = TrainTrip(
            id: RailIdentifier(rawValue: "us:amtrak:experience-regional"),
            source: "amtraker", serviceDate: departure,
            operatorName: "Amtrak", product: "Northeast Regional 174", headsign: "Boston",
            stopTimes: [
                StopTime(station: stations[3], sequence: 0, scheduledDeparture: secondDeparture, expectedDeparture: secondDeparture, plannedPlatform: "12"),
                StopTime(station: stations[4], sequence: 1, scheduledArrival: departure.addingTimeInterval(450 * 60), expectedArrival: departure.addingTimeInterval(450 * 60), plannedPlatform: "5")
            ], capabilities: capabilities
        )
        let secondSegment = JourneyPlanSegment(
            id: "preview-selected-regional", kind: .rail,
            from: place(stations[3]), to: place(stations[4]),
            departure: secondDeparture, arrival: departure.addingTimeInterval(450 * 60),
            serviceName: second.product, resolvedTripID: second.id
        )
        let segments = scenario == .connection ? [firstSegment, secondSegment] : [firstSegment]
        let plan = TrackedJourneyPlan(
            id: UUID(uuidString: "E5AC7710-6B21-4AAA-B420-000000000001")!,
            createdAt: departure.addingTimeInterval(-86400),
            origin: firstSegment.from, destination: segments.last!.to,
            outbound: JourneyPlanDirection(
                fingerprint: "experience-preview", departure: departure,
                arrival: segments.last!.arrival!, childTripIDs: segments.compactMap(\.resolvedTripID),
                selectedSegments: segments
            ), returnDirection: nil, preExistingChildTripIDs: []
        )
        let minutes: TimeInterval = switch scenario {
        case .upcoming: -120
        case .departure, .delayed, .cancelled, .scheduled: -18
        case .underway: 70
        case .connection: 190
        case .ended: 195
        }
        return Self(trips: [trip, second], plan: plan, referenceDate: departure.addingTimeInterval(minutes * 60))
    }

    private static let capabilities = RealtimeCapabilities(
        hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true, hasAlerts: true, granularity: .perStop
    )

    private static func station(_ code: String, _ name: String, _ latitude: Double, _ longitude: Double) -> Station {
        Station(
            id: RailIdentifier(rawValue: "us:amtrak:\(code)"), names: [.init(name)],
            codes: [.sourceNative: code], location: .init(latitude: latitude, longitude: longitude), countryCode: "US"
        )
    }

    private static func place(_ station: Station) -> RailPlace {
        RailPlace(
            id: station.id, kind: .station, displayName: station.displayName, context: "United States",
            countryCode: "US", timeZoneIdentifier: "America/New_York", location: station.location,
            eligibleModes: ["rail"], attributions: []
        )
    }
}
#endif
