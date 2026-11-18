#if DEBUG
import Foundation
import TrainTrackerCore

/// A single repeatable train on the real corridor. No phone location or paid service is needed.
enum HudsonWindowQA {
    @MainActor static func libraries(arguments: [String]) -> (TripLibrary, JourneyPlanLibrary?)? {
        guard arguments.contains("-HudsonWindowQA") else { return nil }
        let now = Date.now
        let point = arguments.contains("-HudsonManualQA") ? [] : [position(near: .bridge, at: now)]
        let train = trip(at: now, positions: point)
        let domain = "Roundhouse.HudsonWindowQA"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        let archive = TripArchive(defaults: defaults)
        try? archive.save([train], lastChecks: [train.id: now])
        let library = TripLibrary(backendSnapshots: TripUpdatesQASource(latest: train),
                                  pushCoordinator: JourneyPlanPreviewPushCoordinator(), archive: archive)
        return (library, try? JourneyPlanLibrary(tripLibrary: library, archive: JourneyPlanPreviewArchive(plans: [])))
    }

    static func position(near landmark: HudsonLandmark, at date: Date, source: PositionSource = .real) -> VehiclePosition {
        VehiclePosition(coordinate: .init(latitude: landmark.location.coordinate.latitude, longitude: landmark.location.coordinate.longitude),
                        source: source, confidence: 1, asOf: date)
    }

    static func trip(at now: Date, product: String = "Empire Service 281", positions: [VehiclePosition] = [],
                     reversed: Bool = false, bridgeReport: Date? = nil, passedWithoutReport: Bool = false) -> TrainTrip {
        let points: [HudsonLandmark] = reversed ? [.albany, .bridge, .manhattan] : [.manhattan, .bridge, .albany]
        let calls = points.enumerated().map { index, place in
            let arrival = now.addingTimeInterval(TimeInterval((index - 1) * 60 * 60))
            let name = place == .bridge ? "Poughkeepsie" : place.name
            let code = place.stationCode!
            let station = Station(id: .init(rawValue: "us:amtraker:" + code), names: [.init(name)], codes: [.sourceNative: code],
                                  location: .init(latitude: place.location.coordinate.latitude, longitude: place.location.coordinate.longitude),
                                  countryCode: "US")
            return StopTime(station: station, sequence: index, scheduledArrival: index == 0 ? nil : arrival,
                            scheduledDeparture: index == points.count - 1 ? nil : arrival.addingTimeInterval(120),
                            isPassed: place == .bridge && passedWithoutReport,
                            arrivalObservedAt: place == .bridge ? bridgeReport : nil)
        }
        return TrainTrip(id: .init(rawValue: "us:amtraker:281-hudson"), source: "amtraker", serviceDate: now,
                         operatorName: "Amtrak", product: product, headsign: points.last!.name, stopTimes: calls,
                         positions: positions, capabilities: .init(hasPositions: !positions.isEmpty, hasPlatforms: false,
                                                                   hasRealtimeDelays: false, hasAlerts: false, granularity: .perStop))
    }
}
#endif
