#if DEBUG
import EventKit
import SwiftUI
import TrainTrackerCore

/// Synthetic, in-memory fixtures for rendered QA. Never reads or writes Calendar.
@MainActor
struct CalendarImportPreviewView: View {
    @State private var library: JourneyPlanLibrary?
    @State private var tripLibrary: TripLibrary
    private let client = CalendarImportPreviewClient()

    init() {
        let fixtures = CalendarImportPreviewClient.savedJourneys()
        let trips = TripLibrary(
            trips: fixtures.trips, sharingClient: TripSharingClient(baseURL: nil),
            pushCoordinator: JourneyPlanPreviewPushCoordinator(),
            archive: nil, automaticRefreshEnabled: false
        )
        _tripLibrary = State(initialValue: trips)
        _library = State(initialValue: try? JourneyPlanLibrary(
            tripLibrary: trips, archive: JourneyPlanPreviewArchive(plans: fixtures.plans)
        ))
    }

    var body: some View {
        if let library {
            CalendarImportView(store: CalendarImportStore(client: client, preferences: CalendarImportPreferences(defaults: nil))) { _, _ in }
                .environment(library)
                .environment(tripLibrary)
        }
    }
}

private struct CalendarImportPreviewClient: CalendarImportClientProtocol {
    var authorizationStatus: EKAuthorizationStatus { .fullAccess }
    func requestAccess() async throws -> Bool { true }
    func fetchCalendars() async throws -> [CalendarDescriptor] {
        [
            CalendarDescriptor(id: "qa-travel", title: "Travel", sourceTitle: "On My iPhone"),
            CalendarDescriptor(id: "qa-work", title: "Work trips", sourceTitle: "On My iPhone")
        ]
    }
    func fetchCandidates(
        window: DateInterval, includingEventKeys: Set<String>, selectedCalendarIDs: Set<String>?
    ) async throws -> [CalendarJourneyCandidate] {
        return Self.events.filter { event in
            let calendarID = event.calendarTitle == "Work trips" ? "qa-work" : "qa-travel"
            return (selectedCalendarIDs?.contains(calendarID) ?? true)
                && event.startDate < window.end && event.endDate > window.start
        }.compactMap { CalendarImportClient.candidate(for: $0, includingEventKeys: includingEventKeys) }
    }

    static var events: [CalendarEventSnapshot] {
        let start = ISO8601DateFormatter().date(from: "2026-09-15T13:30:00Z")!
        return [
            "Amtrak 176: Washington, DC → New York, NY",
            "Eurostar 9032: London St. Pancras → Paris Gare du Nord",
            "Amtrak Acela 2151: Boston → New York",
            "Amtrak 179: New York → Washington, DC",
            "Canceled: Amtrak 89 New York → Philadelphia"
        ].enumerated().map { index, title in
            var departure = start.addingTimeInterval(Double(index) * 86_400)
            if index == 1 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Europe/London")!
                departure = calendar.startOfDay(for: departure)
            }
            return CalendarEventSnapshot(
                eventIdentifier: "qa-event-\(index)", calendarTitle: index == 3 ? "Work trips" : "Travel", title: title,
                notes: nil, location: nil, startDate: departure,
                endDate: departure.addingTimeInterval(index == 1 ? 86_400 : 10_800), isAllDay: index == 1,
                timeZoneIdentifier: index == 1 ? "Europe/London" : "America/New_York", isCancelled: index == 4
            )
        }
    }

    static func savedJourneys() -> (plans: [TrackedJourneyPlan], trips: [TrainTrip]) {
        var plans: [TrackedJourneyPlan] = []
        var trips: [TrainTrip] = []
        for (index, event) in events.enumerated() where index >= 2 {
            guard let classification = CalendarJourneyClassifier.classify(event),
                  let originName = classification.originGuess,
                  let destinationName = classification.destinationGuess else { continue }
            let wasEdited = index == 3
            let reviewedDestination = wasEdited ? "Philadelphia" : destinationName
            let reviewedNumber = wasEdited ? "175" : classification.trainNumberGuess
            let departure = wasEdited ? event.startDate.addingTimeInterval(-3_600) : event.startDate
            let arrival = wasEdited ? departure.addingTimeInterval(90 * 60) : event.endDate
            let origin = place(named: originName)
            let destination = place(named: reviewedDestination)
            let trip = savedTrip(index: index, origin: origin, destination: destination, number: reviewedNumber, departure: departure, arrival: arrival)
            trips.append(trip)
            let details = CalendarJourneyDetails(
                originName: originName, destinationName: reviewedDestination, trainNumber: reviewedNumber,
                departureDate: departure, timeZoneIdentifier: event.timeZoneIdentifier, isAllDay: event.isAllDay
            )
            plans.append(TrackedJourneyPlan(
                id: UUID(), createdAt: departure.addingTimeInterval(-86_400), origin: origin, destination: destination,
                outbound: JourneyPlanDirection(
                    fingerprint: "calendar-preview-\(index)", departure: departure, arrival: arrival, childTripIDs: [trip.id]
                ),
                returnDirection: nil, preExistingChildTripIDs: [],
                calendarSource: CalendarJourneySource(
                    eventKey: event.importSource.eventKey,
                    revision: wasEdited ? "before-edit" : event.importSource.revision,
                    details: details
                )
            ))
        }
        return (plans, trips)
    }

    private static func place(named name: String) -> RailPlace {
        let station: (code: String, name: String, latitude: Double, longitude: Double)
        switch name {
        case "Boston": station = ("BOS", "Boston South Station", 42.3522, -71.0552)
        case "New York", "New York, NY": station = ("NYP", "New York Penn Station", 40.7506, -73.9935)
        case "Philadelphia": station = ("PHL", "Philadelphia 30th Street", 39.9556, -75.1820)
        default: station = ("WAS", "Washington Union Station", 38.8971, -77.0064)
        }
        return RailPlace(
            id: RailIdentifier(rawValue: "us:amtrak:\(station.code)"), kind: .station, displayName: station.name,
            context: "United States", countryCode: "US", timeZoneIdentifier: "America/New_York",
            location: GeoCoordinate(latitude: station.latitude, longitude: station.longitude),
            eligibleModes: ["longDistanceRail"], attributions: ["Synthetic QA timetable"]
        )
    }

    private static func savedTrip(
        index: Int, origin: RailPlace, destination: RailPlace, number: String?, departure: Date, arrival: Date
    ) -> TrainTrip {
        func station(_ place: RailPlace) -> Station {
            Station(
                id: place.id, names: [LocalizedStationName(place.displayName, localeIdentifier: "en")],
                location: place.location, countryCode: place.countryCode, operatorHints: ["Amtrak"]
            )
        }
        return TrainTrip(
            id: RailIdentifier(rawValue: "us:calendar-preview:trip-\(index)"), source: "calendar-preview",
            serviceDate: departure, operatorName: "Amtrak", product: "\(index == 2 ? "Acela" : "Northeast Regional") \(number ?? "")",
            headsign: destination.displayName,
            stopTimes: [
                StopTime(station: station(origin), sequence: 1, scheduledDeparture: departure, plannedPlatform: "4"),
                StopTime(station: station(destination), sequence: 2, scheduledArrival: arrival, plannedPlatform: "7")
            ],
            capabilities: RealtimeCapabilities(
                hasPositions: false, hasPlatforms: true, hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop
            )
        )
    }
}
#endif
