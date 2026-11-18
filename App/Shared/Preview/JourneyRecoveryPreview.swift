#if DEBUG
import Foundation
import TrainTrackerCore

/// A delayed Paris arrival leaves three minutes to change in Brussels. Its original reservation
/// stays in the archive when the rider follows the later Brussels–Amsterdam service.
struct JourneyRecoveryPreview: JourneySearching {
    static let date = Date(timeIntervalSince1970: 1_795_008_240) // 14:24 in Brussels.
    static let originalID = UUID(uuidString: "31C9BDF0-607B-42C2-A603-25599CDF744D")!
    static let paris = place("FR-PNO", "Paris Nord", "FR", 48.88, 2.35, "Europe/Paris")
    static let brussels = place("BE-BMI", "Bruxelles-Midi", "BE", 50.84, 4.34, "Europe/Brussels")
    static let amsterdam = place("NL-ASD", "Amsterdam Centraal", "NL", 52.38, 4.90, "Europe/Amsterdam")

    static func time(_ minutes: Int) -> Date { date.addingTimeInterval(Double(minutes) * 60) }

    static let incoming = train("Eurostar 9321", from: paris, to: brussels, start: -75, end: 0,
                                estimatedEnd: 20, track: "4")
    static let booked = train("Eurostar 9369", from: brussels, to: amsterdam, start: 23, end: 132, track: "9")
    static let fallback = train("Eurocity Direct 9547", from: brussels, to: amsterdam, start: 88, end: 212, track: "6")

    static var original: TrackedJourneyPlan {
        let legs = [segment(incoming, from: paris, to: brussels), segment(booked, from: brussels, to: amsterdam)]
        return TrackedJourneyPlan(id: originalID, createdAt: time(-900), origin: paris, destination: amsterdam,
            outbound: JourneyPlanDirection(fingerprint: "paris–amsterdam", departure: time(-75), arrival: time(132),
                childTripIDs: [incoming.id, booked.id], selectedSegments: legs),
            returnDirection: nil, preExistingChildTripIDs: [])
    }

    @MainActor static var seed: JourneyPlanPreviewData {
        JourneyPlanPreviewData(trips: [incoming, booked], plans: [original], showsPushWarning: false, referenceDate: date)
    }

    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] { [] }

    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        guard criteria.originID == Self.brussels.id, criteria.destinationID == Self.amsterdam.id else {
            throw JourneySearchClient.ClientError.serviceUnavailable
        }
        let options = [Self.option(Self.booked), Self.option(Self.fallback)]
        return JourneySearchPage(generatedAt: Self.date, expiresAt: Self.time(10), options: options,
            previousCursor: nil, nextCursor: nil, warnings: [], attributions: ["Sample timetable"])
    }

    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution {
        guard trackingTokens == [Self.fallback.id.rawValue] else { throw JourneySearchClient.ClientError.invalidRequest }
        return Self.resolution(for: Self.fallback)
    }

    static func resolution(for trip: TrainTrip) -> JourneyPlanResolution {
        let option = option(trip)
        return JourneyPlanResolution(directions: [.init(fingerprint: option.fingerprint, originStationID: brussels.id,
            destinationStationID: amsterdam.id, departure: option.startTime, arrival: option.endTime,
            segments: [.init(segmentID: trip.id.rawValue, trip: trip, failure: nil)])])
    }

    static func option(_ trip: TrainTrip, cancelled: Bool = false) -> JourneyOption {
        let stops = trip.stopTimes
        let from = JourneyCall(place: brussels, city: nil, scheduledArrival: nil, scheduledDeparture: stops[0].scheduledDeparture,
            expectedArrival: nil, expectedDeparture: nil, plannedPlatform: stops[0].plannedPlatform, expectedPlatform: nil, isCancelled: false)
        let to = JourneyCall(place: amsterdam, city: nil, scheduledArrival: stops[1].scheduledArrival, scheduledDeparture: nil,
            expectedArrival: nil, expectedDeparture: nil, plannedPlatform: stops[1].plannedPlatform, expectedPlatform: nil, isCancelled: false)
        let rail = RailJourneySegment(id: trip.id.rawValue, tripID: trip.id, serviceDate: date, operatorName: trip.operatorName,
            product: trip.product, trainNumber: nil, trainName: nil, from: from, to: to, intermediateCalls: [],
            isCancelled: cancelled, isRealtime: false, isTrackable: true, untrackableReason: nil)
        return JourneyOption(id: rail.id, fingerprint: rail.id, startTime: from.scheduledDeparture!, endTime: to.scheduledArrival!,
            duration: to.scheduledArrival!.timeIntervalSince(from.scheduledDeparture!), transferCount: 0, segments: [.rail(rail)],
            badges: [], trackability: .init(trackableRailSegments: 1, totalRailSegments: 1), realtimeFreshness: nil,
            attributions: ["Sample timetable"], trackingToken: rail.id)
    }

    static func train(_ name: String, from: RailPlace = brussels, to: RailPlace = amsterdam,
                      start: Int, end: Int, estimatedEnd: Int? = nil, track: String = "6", cancelled: Bool = false) -> TrainTrip {
        let operatorName = name.hasPrefix("Eurostar") ? "Eurostar" : "Eurocity Direct"
        return TrainTrip(id: RailIdentifier(rawValue: name), source: "fixture", serviceDate: date, operatorName: operatorName,
            product: name, headsign: to.displayName, stopTimes: [
                StopTime(station: station(from), sequence: 0, scheduledDeparture: time(start),
                         expectedPlatform: track, isCancelled: cancelled),
                StopTime(station: station(to), sequence: 1, scheduledArrival: time(end),
                         expectedArrival: estimatedEnd.map(time), expectedPlatform: track, isCancelled: cancelled)
            ], capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true,
                                                   hasAlerts: true, granularity: .perStop), sourceFetchedAt: date)
    }

    static func segment(_ trip: TrainTrip, from: RailPlace, to: RailPlace) -> JourneyPlanSegment {
        JourneyPlanSegment(id: trip.id.rawValue, kind: .rail, from: from, to: to,
            departure: trip.stopTimes.first?.scheduledDeparture, arrival: trip.stopTimes.last?.scheduledArrival,
            serviceName: trip.product, resolvedTripID: trip.id)
    }

    private static func station(_ place: RailPlace) -> Station {
        Station(id: place.id, names: [.init(place.displayName)], codes: [:], location: place.location, countryCode: place.countryCode)
    }

    private static func place(_ id: String, _ name: String, _ country: String, _ lat: Double, _ lon: Double, _ zone: String) -> RailPlace {
        RailPlace(id: RailIdentifier(rawValue: id), kind: .station, displayName: name, context: country, countryCode: country,
            timeZoneIdentifier: zone, location: .init(latitude: lat, longitude: lon), eligibleModes: ["rail"], attributions: [])
    }
}
#endif
