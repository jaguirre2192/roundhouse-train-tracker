import CoreLocation
import TrainTrackerCore

/// Left-to-right on the print is always south to north, in either direction of travel.
enum HudsonLandmark: String, CaseIterable, Identifiable {
    case manhattan, highlands, bridge, albany
    var id: Self { self }

    var name: String {
        switch self {
        case .manhattan: "Manhattan"
        case .highlands: "Hudson Highlands"
        case .bridge: "Mid-Hudson Bridge"
        case .albany: "Albany–Rensselaer"
        }
    }

    var caption: String {
        switch self {
        case .manhattan: "The Empire Service meets the city beneath Midtown. Upstairs, Moynihan Train Hall opens onto Eighth Avenue."
        case .highlands: "Here the Hudson narrows between two ridges. Breakneck rises on the east bank and Storm King faces it across the water."
        case .bridge: "Look for the pointed arches on the towers at Poughkeepsie. This suspension bridge has linked the two banks since 1930."
        case .albany: "Albany is across the river. The train calls at Rensselaer, on the east bank of the Hudson."
        }
    }

    /// Focal points on the illustrated panorama. These fractions describe ink, not track mileage.
    var printFraction: Double {
        switch self {
        case .manhattan: 0.09
        case .highlands: 0.33
        case .bridge: 0.62
        case .albany: 0.93
        }
    }

    var location: CLLocation {
        switch self {
        case .manhattan: CLLocation(latitude: 40.751, longitude: -73.994)
        case .highlands: CLLocation(latitude: 41.441, longitude: -73.977)
        case .bridge: CLLocation(latitude: 41.704, longitude: -73.946)
        case .albany: CLLocation(latitude: 42.642, longitude: -73.742)
        }
    }

    var stationCode: String? {
        switch self {
        case .manhattan: "NYP"
        case .bridge: "POU"
        case .albany: "ALB"
        case .highlands: nil
        }
    }

    var sourceURL: URL {
        switch self {
        case .manhattan: URL(string: "https://www.amtrak.com/stations/nyp")!
        case .highlands: URL(string: "https://parks.ny.gov/documents/parks/HudsonHighlandsHighlandEagleViewingMap.pdf")!
        case .bridge: URL(string: "https://nysba.ny.gov/bridge/mid-hudson")!
        case .albany: URL(string: "https://www.amtrak.com/stations/alb")!
        }
    }
}

enum HudsonWindowGuide {
    /// Starting pages for browsing when a passenger joins the corridor partway along.
    private static let guidePage: [String: HudsonLandmark] = [
        "NYP": .manhattan, "YNY": .manhattan, "CRT": .highlands, "POU": .bridge,
        "RHI": .bridge, "HUD": .albany, "ALB": .albany,
    ]

    static func matches(_ trip: TrainTrip, stops: [StopTime]? = nil) -> Bool {
        guard AmtrakPositionMatcher.isAmtrak(trip),
              trip.product.localizedCaseInsensitiveContains("Empire Service") else { return false }
        let stopsOnTrain = Set((stops ?? trip.stopTimes).compactMap { AmtrakPositionMatcher.amtrakCode(for: $0.station) })
        return stopsOnTrain.intersection(guidePage.keys).count >= 2
    }

    static func firstLandmark(for trip: TrainTrip?, stops: [StopTime]? = nil) -> HudsonLandmark {
        for stop in stops ?? trip?.stopTimes ?? [] {
            if let code = AmtrakPositionMatcher.amtrakCode(for: stop.station), let page = guidePage[code] { return page }
        }
        return .manhattan
    }

    /// A dated train observation can select a scene. Timetable progress and the phone's GPS cannot.
    static func nearbyLandmark(on trip: TrainTrip, at now: Date) -> HudsonLandmark? {
        guard matches(trip), !trip.isCancelled else { return nil }
        if let fix = trip.positions.filter({ $0.source == .real && TrainPositionStatus(position: $0, now: now) == .live })
            .max(by: { $0.asOf < $1.asOf }) {
            guard fix.confidence >= 0.5,
                  CLLocationCoordinate2DIsValid(.init(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude))
            else { return nil }
            let here = CLLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
            return HudsonLandmark.allCases.first { here.distance(from: $0.location) <= ($0 == .highlands ? 7_000 : 3_500) }
        }
        let recentCalls: [(stop: StopTime, observed: Date)] = trip.stopTimes.compactMap { stop in
            guard !stop.isCancelled, stop.hasConfirmedArrival(at: now),
                  let date = [stop.arrivalObservedAt, stop.hasConfirmedPassage(at: now) ? stop.passageObservedAt : nil]
                    .compactMap({ $0 }).filter({ $0 <= now.addingTimeInterval(120) }).max(),
                  now.timeIntervalSince(date) <= TrainPositionStatus.liveInterval else { return nil }
            return (stop, date)
        }
        guard let call = recentCalls.max(by: { $0.observed < $1.observed }),
              let code = AmtrakPositionMatcher.amtrakCode(for: call.stop.station) else { return nil }
        return HudsonLandmark.allCases.first { $0.stationCode == code }
    }
}
