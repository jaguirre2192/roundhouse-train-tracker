#if DEBUG
import Foundation
import TrainTrackerCore

/// The station zones and scheduled instants from Transitous's 19 November 2026 Eurostar 9004.
@MainActor
enum StationClockPreview {
    static var seed: JourneyPlanPreviewData {
        let departure = ISO8601DateFormatter().date(from: "2026-11-19T07:01:00Z")!
        let arrival = ISO8601DateFormatter().date(from: "2026-11-19T09:21:00Z")!
        let london = Station(id: .init(rawValue: "eurostar:STP"), names: [.init("London St Pancras")],
                             codes: [.sourceNative: "STP"], location: .init(latitude: 51.5322, longitude: -0.1261),
                             countryCode: "GB", timeZoneIdentifier: "Europe/London")
        let paris = Station(id: .init(rawValue: "eurostar:PNO"), names: [.init("Paris Nord")],
                            codes: [.sourceNative: "PNO"], location: .init(latitude: 48.8809, longitude: 2.3553),
                            countryCode: "FR", timeZoneIdentifier: "Europe/Paris")
        let trip = TrainTrip(id: .init(rawValue: "eurostar:9004"), source: "fixture", serviceDate: departure,
                             operatorName: "Eurostar", product: "Eurostar 9004", headsign: paris.displayName,
                             stopTimes: [.init(station: london, sequence: 0, scheduledDeparture: departure),
                                         .init(station: paris, sequence: 1, scheduledArrival: arrival)],
                             capabilities: .init(hasPositions: false, hasPlatforms: false, hasRealtimeDelays: false,
                                                 hasAlerts: false, granularity: .perStop),
                             sourceFetchedAt: departure)
        return .init(trips: [trip], plans: [], showsPushWarning: false,
                     referenceDate: departure.addingTimeInterval(3600))
    }
}
#endif
