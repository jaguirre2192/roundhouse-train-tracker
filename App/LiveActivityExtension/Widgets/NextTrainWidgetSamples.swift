import Foundation
import TrainTrackerCore

/// Realistic sample journeys for the widget gallery, the placeholder and the DEBUG preview
/// harness. Stations are New York Penn to Philadelphia, timed relative to `date`.
enum NextTrainWidgetSamples {
    enum State: String, CaseIterable, Identifiable {
        case sample, empty, upcoming, underway, delayed, cancelled, unchecked, arrived, ended, foreignZone = "foreign-zone"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sample: "Gallery sample"
            case .empty: "No tracked trains"
            case .upcoming: "Next train upcoming"
            case .underway: "Underway"
            case .delayed: "Delayed"
            case .cancelled: "Canceled"
            case .unchecked: "Saved, not checked"
            case .arrived: "Arrived, next train"
            case .ended: "Ended"
            case .foreignZone: "Station zone differs"
            }
        }
    }

    static func gallery(at date: Date) -> WidgetTripSnapshot {
        WidgetTripSnapshot(generatedAt: date, trains: [
            acela(at: date, departure: 25, delay: 7, checked: date.addingTimeInterval(-120)),
            acela(at: date, number: "2155", departure: 145, delay: nil, checked: date.addingTimeInterval(-120)),
        ])
    }

    static func snapshot(for state: State, at date: Date) -> WidgetTripSnapshot? {
        let checked = date.addingTimeInterval(-3 * 60)
        switch state {
        case .sample: return gallery(at: date)
        case .empty: return WidgetTripSnapshot(generatedAt: date, trains: [])
        case .upcoming:
            return WidgetTripSnapshot(generatedAt: date, trains: [
                acela(at: date, departure: 40, delay: 1, checked: checked),
                acela(at: date, number: "2155", departure: 160, delay: nil, checked: checked),
            ])
        case .underway:
            return WidgetTripSnapshot(generatedAt: date, trains: [
                acela(at: date, departure: -20, delay: 2, checked: date.addingTimeInterval(-60)),
                acela(at: date, number: "2155", departure: 100, delay: nil, checked: checked),
            ])
        case .delayed:
            return WidgetTripSnapshot(generatedAt: date, trains: [acela(at: date, departure: 25, delay: 12, checked: checked)])
        case .cancelled:
            return WidgetTripSnapshot(generatedAt: date, trains: [
                acela(at: date, departure: 35, delay: nil, checked: checked, cancelled: true),
                acela(at: date, number: "2155", departure: 95, delay: nil, checked: checked),
            ])
        case .unchecked:
            return WidgetTripSnapshot(generatedAt: date, trains: [acela(at: date, departure: 50, delay: 6, checked: nil)])
        case .arrived:
            return WidgetTripSnapshot(generatedAt: date, trains: [
                acela(at: date, departure: -95, delay: 4, checked: checked),
                acela(at: date, number: "2155", departure: 70, delay: nil, checked: checked),
            ])
        case .ended:
            return WidgetTripSnapshot(generatedAt: date, trains: [acela(at: date, departure: -160, delay: 0, checked: checked)])
        case .foreignZone:
            return WidgetTripSnapshot(generatedAt: date, trains: [tgv(at: date, checked: checked)])
        }
    }

    private static func acela(
        at date: Date, number: String = "2151", departure: Double, delay: Double?, checked: Date?, cancelled: Bool = false
    ) -> WidgetTripSnapshot.Train {
        func time(_ minutes: Double) -> Date { date.addingTimeInterval(minutes * 60) }
        func expected(_ minutes: Double) -> Date? { delay.map { time(minutes + $0) } }
        // The device's own zone, so samples never show a station-zone label they don't need.
        let zone = TimeZone.autoupdatingCurrent.identifier
        func stop(_ name: String, _ code: String, arrival: Double?, departure: Double?, platform: String? = nil) -> WidgetTripSnapshot.Stop {
            WidgetTripSnapshot.Stop(
                name: name, code: code, timeZoneIdentifier: zone,
                scheduledArrival: arrival.map(time), scheduledDeparture: departure.map(time),
                expectedArrival: arrival.flatMap(expected), expectedDeparture: departure.flatMap(expected),
                platform: platform, platformKind: .track, isCancelled: cancelled
            )
        }
        return WidgetTripSnapshot.Train(
            id: "sample:amtrak:\(number)", serviceName: "Acela \(number)",
            stops: [
                stop("New York Penn Station", "NYP", arrival: nil, departure: departure, platform: "7"),
                stop("Newark Penn Station", "NWK", arrival: departure + 15, departure: departure + 17),
                stop("Trenton", "TRE", arrival: departure + 45, departure: departure + 46),
                stop("Philadelphia 30th Street", "PHL", arrival: departure + 80, departure: nil, platform: "4"),
            ],
            lastSuccessfulCheck: checked
        )
    }

    private static func tgv(at date: Date, checked: Date) -> WidgetTripSnapshot.Train {
        func time(_ minutes: Double) -> Date { date.addingTimeInterval(minutes * 60) }
        return WidgetTripSnapshot.Train(
            id: "sample:sncf:6611", serviceName: "TGV INOUI 6611",
            stops: [
                WidgetTripSnapshot.Stop(
                    name: "Paris Gare de Lyon", code: nil, timeZoneIdentifier: "Europe/Paris",
                    scheduledDeparture: time(45), expectedDeparture: time(45), platform: "K", platformKind: .platform
                ),
                WidgetTripSnapshot.Stop(
                    name: "Lyon Part-Dieu", code: nil, timeZoneIdentifier: "Europe/Paris",
                    scheduledArrival: time(161), expectedArrival: time(161), platformKind: .platform
                ),
            ],
            lastSuccessfulCheck: checked
        )
    }
}
