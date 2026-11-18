#if DEBUG
import Foundation
import TrainTrackerCore

/// Authored traces of two failure modes. The normal library, progress, ticket, and map all
/// consume these snapshots. Only the clock and the supplier are controlled by the fixture.
enum TripUpdatesQA: String {
    case amtrak, spain
    enum Stage { case baseline, interruption, recovery, timetableOnly }

    init?(arguments: [String]) {
        if arguments.contains("-AmtrakSignalGapQA") { self = .amtrak }
        else if arguments.contains("-SpainDelayedStopQA") || arguments.contains("-SpainTimetablePhoneQA") { self = .spain }
        else { return nil }
    }

    @MainActor static func libraries(arguments: [String]) -> (TripLibrary, JourneyPlanLibrary?)? {
        guard let scenario = Self(arguments: arguments) else { return nil }
        let reference = Date.now
        let timetableOnly = arguments.contains("-SpainTimetablePhoneQA")
        let base = scenario.snapshot(timetableOnly ? .timetableOnly : .baseline, now: reference)
        let restoring = arguments.contains("-TripUpdatesRecoveryQA")
        let archive = scenario.archive(baseline: base, restoring: restoring)
        let latest = timetableOnly ? base : scenario.snapshot(restoring ? .recovery : .interruption, now: reference)
        let source = TripUpdatesQASource(latest: latest)
        let meetBoard = arguments.contains("-MeetArrivalBoardQA") && scenario == .amtrak
        let library = TripLibrary(backendSnapshots: source, sharingClient: MeetTrainQA.sharingClient(enabled: meetBoard), pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: archive)
        func place(_ station: Station) -> RailPlace {
            RailPlace(id: station.id, kind: .station, displayName: station.displayName, context: "",
                      countryCode: station.countryCode, timeZoneIdentifier: scenario == .amtrak ? "America/New_York" : "Europe/Madrid",
                      location: station.location, eligibleModes: ["rail"], attributions: [])
        }
        let arrivalCall = base.stopTimes[meetBoard ? 1 : 2]
        let from = place(base.origin!), to = place(arrivalCall.station)
        let departure = base.stopTimes[0].scheduledDeparture!, arrival = arrivalCall.scheduledArrival!
        let leg = JourneyPlanSegment(id: "booked-train", kind: .rail, from: from, to: to,
                                     departure: departure, arrival: arrival, serviceName: base.product, resolvedTripID: base.id)
        let plan = TrackedJourneyPlan(id: UUID(), createdAt: reference, origin: from, destination: to,
                                      outbound: JourneyPlanDirection(fingerprint: "update-trace", departure: departure,
                                                                     arrival: arrival, childTripIDs: [base.id], selectedSegments: [leg]),
                                      returnDirection: nil, preExistingChildTripIDs: [])
        return (library, try? JourneyPlanLibrary(tripLibrary: library, archive: JourneyPlanPreviewArchive(plans: [plan])))
    }

    func snapshot(_ stage: Stage, now: Date) -> TrainTrip {
        let us = self == .amtrak
        let id = RailIdentifier(rawValue: us ? "us:amtraker:signal-171" : "eu:renfe:ave-03123")
        let stations = us ? [
            station("WAS", "Washington Union", 38.897, -77.007),
            station("BAL", "Baltimore Penn", 39.307, -76.616),
            station("NYP", "New York Penn", 40.751, -73.994),
        ] : [
            station("60000", "Madrid Puerta de Atocha", 40.406, -3.690),
            station("04040", "Zaragoza-Delicias", 41.659, -0.912),
            station("71801", "Barcelona Sants", 41.379, 2.141),
        ]
        func minutes(_ n: Int) -> Date { now.addingTimeInterval(Double(n * 60)) }
        let timetable = stage == .timetableOnly
        let delay = stage == .baseline ? 0 : (us ? 12 : 25)
        let stopTime = minutes(us ? 15 : -10)
        let reported = !us && stage == .recovery
        let calls = [
            StopTime(station: stations[0], sequence: 1, scheduledDeparture: minutes(-70),
                     isPassed: true, passageObservedAt: timetable ? nil : minutes(-69)),
            StopTime(station: stations[1], sequence: 2, scheduledArrival: stopTime,
                     scheduledDeparture: stopTime.addingTimeInterval(120),
                     expectedPlatform: timetable ? nil : (stage == .baseline ? "4" : "7"), isPassed: reported || !us,
                     passageObservedAt: reported ? minutes(-1) : nil),
            StopTime(station: stations[2], sequence: 3, scheduledArrival: minutes(80), expectedArrival: timetable ? nil : minutes(80 + delay)),
        ]
        let segmentStart = stations[reported ? 1 : 0].location
        let segmentEnd = stations[reported ? 2 : 1].location
        let fraction = reported ? 0.10 : 0.70
        let fix = VehiclePosition(coordinate: GeoCoordinate(
            latitude: segmentStart.latitude + (segmentEnd.latitude - segmentStart.latitude) * fraction,
            longitude: segmentStart.longitude + (segmentEnd.longitude - segmentStart.longitude) * fraction
        ), source: .real, confidence: 1, asOf: stage == .baseline ? minutes(-15) : now.addingTimeInterval(-15),
           timestampBasis: us ? nil : .feedPublicationAndMovement)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return TrainTrip(id: id, source: us ? "amtraker" : "renfe", serviceDate: calendar.startOfDay(for: now),
                         operatorName: us ? "Amtrak" : "Renfe", product: us ? "Northeast Regional 171" : "AVE 03123",
                         headsign: stations[2].displayName, stopTimes: calls,
                         positions: timetable || (us && stage == .interruption) ? [] : [fix],
                         capabilities: RealtimeCapabilities(hasPositions: !timetable, hasPlatforms: !timetable, hasRealtimeDelays: !timetable,
                                                            hasAlerts: false, granularity: .perStop),
                         sourceFetchedAt: stage == .baseline ? minutes(-14) : now)
    }

    func referenceDate(in baseline: TrainTrip) -> Date { baseline.stopTimes[0].scheduledDeparture!.addingTimeInterval(70 * 60) }

    @MainActor func archive(baseline: TrainTrip, restoring: Bool) -> TripArchive {
        let defaults = UserDefaults(suiteName: "Roundhouse.RiderUpdateQA.\(rawValue)")!
        defaults.removePersistentDomain(forName: "Roundhouse.RiderUpdateQA.\(rawValue)")
        let archive = TripArchive(defaults: defaults)
        let now = referenceDate(in: baseline)
        let current = restoring ? snapshot(.interruption, now: now) : baseline
        let checked = restoring ? now : now.addingTimeInterval(-14 * 60)
        var journal = TripChangeJournal()
        journal.observe(previous: baseline, current: current, hadConfirmedCheck: restoring, at: checked)
        try? archive.save([current], lastChecks: [current.id: checked], journalUpdate: (current.id, journal))
        return archive
    }

    private func station(_ id: String, _ name: String, _ lat: Double, _ lon: Double) -> Station {
        Station(id: RailIdentifier(rawValue: id), names: [LocalizedStationName(name)],
                location: GeoCoordinate(latitude: lat, longitude: lon), countryCode: self == .amtrak ? "US" : "ES")
    }
}

struct TripUpdatesQASource: TripDataProviding {
    let latest: TrainTrip
    func searchStations(query: String, source: RailSource) async throws -> [Station] { [] }
    func board(stationID: RailIdentifier, at date: Date, direction: BoardDirection, source: RailSource?) async throws -> [StopTimeSummary] { [] }
    func trip(id: RailIdentifier, serviceDate: Date, source: RailSource?) async throws -> TrainTrip { latest }
    func enrichedTrip(_ trip: TrainTrip) async throws -> TrainTrip { latest }
}
#endif
