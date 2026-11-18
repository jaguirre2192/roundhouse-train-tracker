#if DEBUG
import Foundation
import TrainTrackerCore

/// Two separately selected, publicly scheduled trains on 19 November 2026. Station coordinates,
/// track assignments and timetable instants come from Transitous's Austrian reference data.
@MainActor
enum PublishedConnectionPreview {
    private static func place(_ id: String, _ name: String, _ latitude: Double, _ longitude: Double) -> RailPlace {
        .init(id: .init(rawValue: id), kind: .station, displayName: name, context: "AT", countryCode: "AT",
              timeZoneIdentifier: "Europe/Vienna", location: .init(latitude: latitude, longitude: longitude),
              eligibleModes: ["rail"], attributions: ["Transitous"])
    }

    static var seed: JourneyPlanPreviewData {
        let vienna = place("AT:Meidling", "Wien Meidling", 48.174760, 16.333662)
        let change = place("AT:WienerNeustadt", "Wiener Neustadt Hauptbahnhof", 47.810623, 16.233105)
        let graz = place("AT:Graz", "Graz Hauptbahnhof", 47.072617, 15.416267)
        func time(_ utc: String) -> Date { ISO8601DateFormatter().date(from: "2026-11-19T\(utc):00Z")! }
        func station(_ place: RailPlace) -> Station {
            .init(id: place.id, names: [.init(place.displayName)], location: place.location, countryCode: "AT",
                  timeZoneIdentifier: place.timeZoneIdentifier)
        }
        func train(_ name: String, _ operatorName: String, from: RailPlace, to: RailPlace, start: String, end: String,
                   fromTrack: String, toTrack: String) -> TrainTrip {
            .init(id: .init(rawValue: "AT:\(name)"), source: "fixture", serviceDate: time(start), operatorName: operatorName,
                  product: name, headsign: to.displayName, stopTimes: [
                    .init(station: station(from), sequence: 0, scheduledDeparture: time(start), plannedPlatform: fromTrack),
                    .init(station: station(to), sequence: 1, scheduledArrival: time(end), plannedPlatform: toTrack)
                  ], capabilities: .init(hasPositions: false, hasPlatforms: true, hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop))
        }
        let rex = train("REX 22337", "ÖBB", from: vienna, to: change, start: "12:37", end: "13:19", fromTrack: "1", toTrack: "7")
        let wb = train("WB 1005", "WESTbahn", from: change, to: graz, start: "13:51", end: "15:44", fromTrack: "4", toTrack: "5")
        let segments = [JourneyRecoveryPreview.segment(rex, from: vienna, to: change),
                        JourneyRecoveryPreview.segment(wb, from: change, to: graz)]
        let plan = TrackedJourneyPlan(id: UUID(uuidString: "77588308-39D4-45A2-8D15-64E86150131B")!, createdAt: time("10:00"),
                                      origin: vienna, destination: graz, outbound: .init(fingerprint: "REX22337-WB1005",
                                        departure: time("12:37"), arrival: time("15:44"), childTripIDs: [rex.id, wb.id], selectedSegments: segments),
                                      returnDirection: nil, preExistingChildTripIDs: [])
        return .init(trips: [rex, wb], plans: [plan], showsPushWarning: false, referenceDate: time("13:26"))
    }
}
#endif
