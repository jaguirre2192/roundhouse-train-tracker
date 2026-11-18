#if DEBUG
import TrainTrackerCore
import UIKit

/// Normal tracked journey and locally imported PDF with the plan-only attachment from ticket intake.
enum PlatformBoardQA {
    static let flag = "-PlatformBoardQA"
    static let tripID = RailIdentifier(rawValue: "eu:renfe:boarding-03123")
    static let planID = UUID(uuidString: "B4DBF0BD-8E5A-44CF-BD8A-7726566C336F")!

    static func trip(at now: Date, current: String? = "7", planned: String? = "4", forecast: PlatformForecast? = nil,
                     observedAt: Date? = nil, passed: Bool = false, cancelled: Bool = false) -> TrainTrip {
        let madrid = station("60000", "Madrid Puerta de Atocha", 40.406, -3.690)
        let zaragoza = station("04040", "Zaragoza-Delicias", 41.659, -0.912)
        let barcelona = station("71801", "Barcelona Sants", 41.379, 2.141)
        let stops = [
            StopTime(station: madrid, sequence: 1, scheduledDeparture: now.addingTimeInterval(900),
                     plannedPlatform: planned, expectedPlatform: current, platformForecast: forecast, platformSource: "Renfe",
                     platformObservedAt: observedAt ?? now, isCancelled: cancelled,
                     isPassed: passed, passageObservedAt: passed ? now : nil),
            StopTime(station: zaragoza, sequence: 2, scheduledArrival: now.addingTimeInterval(5_400),
                     scheduledDeparture: now.addingTimeInterval(5_580), expectedPlatform: "2", platformSource: "Renfe"),
            StopTime(station: barcelona, sequence: 3, scheduledArrival: now.addingTimeInterval(9_900)),
        ]
        return TrainTrip(id: tripID, source: "renfe", serviceDate: Calendar(identifier: .iso8601).startOfDay(for: now),
                         operatorName: "Renfe", product: "AVE 03123", headsign: barcelona.displayName, stopTimes: stops,
                         capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: true, hasRealtimeDelays: true,
                                                            hasAlerts: false, granularity: .perStop), sourceFetchedAt: now)
    }

    static func plan(_ trip: TrainTrip) -> TrackedJourneyPlan {
        let from = place(trip.stopTimes[0].station), to = place(trip.stopTimes[2].station)
        let departure = trip.stopTimes[0].scheduledDeparture!, arrival = trip.stopTimes[2].scheduledArrival!
        let segment = JourneyPlanSegment(id: "boarding-qa", kind: .rail, from: from, to: to, departure: departure,
                                         arrival: arrival, serviceName: trip.product, resolvedTripID: trip.id)
        return TrackedJourneyPlan(id: planID, createdAt: departure.addingTimeInterval(-1_800), origin: from, destination: to,
                                  outbound: JourneyPlanDirection(fingerprint: "boarding-qa", departure: departure,
                                      arrival: arrival, childTripIDs: [trip.id], selectedSegments: [segment]),
                                  returnDirection: nil, preExistingChildTripIDs: [])
    }

    @MainActor static func libraries(arguments: [String]) -> (TripLibrary, JourneyPlanLibrary?)? {
        guard arguments.contains(flag) else { return nil }
        let now = Date.now
        let trip = trip(at: now, observedAt: now.addingTimeInterval(-10))
        let defaults = UserDefaults(suiteName: "Roundhouse.PlatformBoardQA")!
        defaults.removePersistentDomain(forName: "Roundhouse.PlatformBoardQA")
        let archive = TripArchive(defaults: defaults)
        try? archive.save([trip], lastChecks: [trip.id: now])
        let library = TripLibrary(backendSnapshots: TripUpdatesQASource(latest: trip),
                                  pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: archive)
        return (library, try? JourneyPlanLibrary(tripLibrary: library, archive: JourneyPlanPreviewArchive(plans: [plan(trip)])))
    }

    @MainActor static func seedTicket(in vault: LocalJourneyTicketStore) async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 360, height: 240))
        let bytes = renderer.pdfData { context in
            context.beginPage()
            "EXAMPLE TICKET\nMadrid → Barcelona".draw(at: CGPoint(x: 24, y: 30), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
            "AVE 03123\nCoach 6 · Seat 14A\nSample for interface testing".draw(
                at: CGPoint(x: 24, y: 116), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let parsed = ParsedTicketImport(suggestion: TicketRouteSuggestion(id: UUID(), sourceDescription: "Example PDF",
            subtitle: "Boarding example", originGuess: "Madrid Puerta de Atocha", destinationGuess: "Barcelona Sants"),
            details: TicketTextDetails(coach: "6", seat: "14A"))
        let imported = try await vault.importPayload(bytes, kind: .pdf, filename: "Madrid to Barcelona.pdf", parsed: parsed)
        _ = try vault.link(id: imported.ticket.id, planID: planID)
    }

    static func place(_ station: Station) -> RailPlace {
        RailPlace(id: station.id, kind: .station, displayName: station.displayName, context: "", countryCode: "ES",
                  timeZoneIdentifier: "Europe/Madrid", location: station.location, eligibleModes: ["rail"], attributions: [])
    }

    private static func station(_ id: String, _ name: String, _ latitude: Double, _ longitude: Double) -> Station {
        Station(id: RailIdentifier(rawValue: id), names: [LocalizedStationName(name)], codes: [.sourceNative: id],
                location: GeoCoordinate(latitude: latitude, longitude: longitude), countryCode: "ES")
    }
}
#endif
