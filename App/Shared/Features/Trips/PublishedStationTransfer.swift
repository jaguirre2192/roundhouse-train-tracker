import Foundation
import TrainTrackerCore

/// Entries whose applicability can be established from the selected station calls.
/// Source: ÖBB-Infrastruktur, Network Statement §4.2.2, minimum transfer times, 2026 and 2027.
/// The two editions were verified separately. Station anchors come from ÖBB's GeoNetz register.
struct PublishedStationTransfer: Equatable, Sendable {
    let minutes: Int
    let source: String
    let sourceURL: URL

    static func find(arrival: StopTime, departure: StopTime, at date: Date, onward: Date? = nil) -> Self? {
        guard let year = edition(at: date),
              onward.map({ edition(at: $0) == year }) ?? true,
              let station = sites.first(where: { $0.matches(arrival.station) && $0.matches(departure.station) })
        else { return nil }
        let minutes: Int
        switch station.rule {
        case .any(let duration): minutes = duration
        case .sameTrack(let duration, let tracks):
            guard let incoming = track(arrival), let outgoing = track(departure),
                  incoming == outgoing, tracks.contains(incoming) else { return nil }
            minutes = duration
        }
        let url = URL(string: "https://infrastruktur.oebb.at/geschaeftspartner/schienennetz/snnb/snnb-\(year)/snnb-\(year)-anhaenge/mindestuebergangszeiten")!
        return Self(minutes: minutes, source: "ÖBB-Infrastruktur · \(year)", sourceURL: url)
    }

    private enum Rule {
        case any(Int)
        case sameTrack(minutes: Int, tracks: ClosedRange<Int>)
    }

    private struct Site {
        let names: [String]
        let latitude: Double
        let longitude: Double
        let rule: Rule

        func matches(_ station: Station) -> Bool {
            guard station.countryCode.uppercased() == "AT",
                  names.contains(station.displayName.lowercased()) else { return false }
            let north = (station.location.latitude - latitude) * 111_320
            let east = (station.location.longitude - longitude) * 111_320 * cos(latitude * .pi / 180)
            return hypot(north, east) < 400
        }
    }

    private static let sites = [
        Site(names: ["wiener neustadt hbf", "wiener neustadt hauptbahnhof"], latitude: 47.81145,
             longitude: 16.23432, rule: .any(5)),
        Site(names: ["ried im innkreis", "ried im innkreis bahnhof"], latitude: 48.20063,
             longitude: 13.48832, rule: .any(2)),
        Site(names: ["salzburg hbf", "salzburg hauptbahnhof"], latitude: 47.81310,
             longitude: 13.04507, rule: .sameTrack(minutes: 3, tracks: 1...9)),
        Site(names: ["klagenfurt hbf", "klagenfurt hauptbahnhof"], latitude: 46.61596,
             longitude: 14.31359, rule: .sameTrack(minutes: 3, tracks: 1...7)),
        // ÖBB lists a separate value for Vienna's S-Bahn platforms 1 and 2.
        Site(names: ["wien hbf", "wien hauptbahnhof"], latitude: 48.18520,
             longitude: 16.37630, rule: .sameTrack(minutes: 4, tracks: 3...12))
    ]

    private static func track(_ stop: StopTime) -> Int? {
        // The reported assignment supersedes the planned one. Predictions never qualify.
        guard let label = stop.displayPlatform?.trimmingCharacters(in: .whitespacesAndNewlines),
              let number = Int(label), label == String(number) else { return nil }
        return number
    }

    private static func edition(at date: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        switch year * 10000 + month * 100 + day {
        case 20251214..<20261213: return 2026
        case 20261213..<20271212: return 2027
        default: return nil
        }
    }
}
