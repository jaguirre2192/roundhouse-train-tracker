import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct RailJourneyStationIdentityTests {
    private let departure = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func legacyWrongCountryRecoversByExactTransitousNativeStationIdentity() {
        let origin = stop("nl-feed_Paris", sequence: 1, country: "FR", latitude: 48.881)
        let destination = stop("nl-feed_Brussels", sequence: 2, country: "BE", latitude: 50.835)
        let progress = progress(
            [origin, destination],
            from: place("nl-feed_Paris", country: "NL", latitude: 1),
            to: place("nl-feed_Brussels", country: "NL", latitude: 2)
        )

        #expect(progress.phase == .underway)
        #expect(progress.stops.map(\.station.id) == [origin.station.id, destination.station.id])
        #expect(progress.departureDate == departure)
        #expect(progress.arrivalDate == departure.addingTimeInterval(60))
    }

    @Test func repeatedNativeStationIdentityDoesNotFallBackToOneNearbyOccurrence() {
        let progress = progress(
            [stop("A", sequence: 1, latitude: 48), stop("A", sequence: 2, latitude: 49),
             stop("B", sequence: 3, latitude: 50)],
            from: place("A", latitude: 48), to: place("B", latitude: 50)
        )
        #expect(progress.phase == .unavailable)
        #expect(progress.stops.isEmpty)
    }

    @Test func srbijavozPlacesRetainTheirNativeStationIdentityAcrossSavedJourneyReload() throws {
        let origin = stop("16052", sequence: 1, country: "RS", latitude: 44.793,
                          id: "rs:srbijavoz:16052")
        let destination = stop("16807", sequence: 2, country: "RS", latitude: 45.25,
                               id: "rs:srbijavoz:16807")
        let places = ["16052", "16807"].map { native in
            place(native, country: "RS", latitude: 1,
                  id: "rail:srbijavoz:station:\(encoded("\(native)\u{1f}RS\u{1f}\u{1f}"))")
        }
        let restored = try JSONDecoder().decode([RailPlace].self, from: JSONEncoder().encode(places))
        let progress = progress([origin, destination], from: restored[0], to: restored[1])

        #expect(progress.phase == .underway)
        #expect(progress.stops.map(\.station.id) == [origin.station.id, destination.station.id])
        #expect(progress.timingBasis == .scheduled)
    }

    @Test func srbijavozStationIdentityRequiresItsSerbianNamespaceAndCountry() {
        let payload = encoded("16052\u{1f}RS\u{1f}\u{1f}")
        #expect(BackendRailPlaceStationIdentity.stationID(for:
            RailIdentifier(rawValue: "rail:srbijavoz:station:\(payload)"))?.rawValue == "rs:srbijavoz:16052")
        for identifier in [
            "rail:srbijavoz:station:\(encoded("16052\u{1f}SK\u{1f}\u{1f}"))",
            "rail:srbijavoz:city:\(payload)", "rail:srbijavoz:station:\(payload)=",
        ] {
            #expect(BackendRailPlaceStationIdentity.stationID(for: RailIdentifier(rawValue: identifier)) == nil)
        }
        let wrongProvider = stop("16052", sequence: 1, country: "RS", latitude: 44.793,
                                 id: "eu:transitous:16052")
        let destination = stop("16807", sequence: 2, country: "RS", latitude: 45.25, id: "rs:srbijavoz:16807")
        let from = place("16052", country: "RS", latitude: 1, id: "rail:srbijavoz:station:\(payload)")
        let to = place("16807", country: "RS", latitude: 2,
                       id: "rail:srbijavoz:station:\(encoded("16807\u{1f}RS\u{1f}\u{1f}"))")
        #expect(progress([wrongProvider, destination], from: from, to: to).phase == .unavailable)
    }

    @Test func nativeIdentityDoesNotCrossProviderOrRegionNamespaces() {
        for identifier in ["eu:other:A", "us:transitous:A"] {
            let progress = progress(
                [stop("A", sequence: 1, country: "FR", latitude: 48, id: identifier),
                 stop("B", sequence: 2, latitude: 50)],
                from: place("A", country: "NL", latitude: 1), to: place("B", latitude: 50)
            )
            #expect(progress.phase == .unavailable)
            #expect(progress.stops.isEmpty)
        }
    }

    @Test func malformedAndCityIdentifiersCannotUseTheStationGeographicFallback() {
        let payloads = ["A\u{1f}FR\u{1f}\u{1f}extra", "\u{1f}FR\u{1f}\u{1f}",
                        "A\u{1f}fr\u{1f}\u{1f}", "A\u{1f}FR\u{1f}48\u{1f}2"]
        let valid = encoded("A\u{1f}FR\u{1f}\u{1f}")
        let identifiers = payloads.map { "rail:transitous:station:\(encoded($0))" } + [
            "rail:transitous:station:!invalid", "rail:transitous:station:\(valid)=",
            "rail:other:station:\(valid)", "rail:transitous:city:\(encoded("A\u{1f}FR\u{1f}48\u{1f}2"))",
        ]
        for identifier in identifiers {
            let progress = progress(
                [stop("A", sequence: 1, latitude: 48), stop("B", sequence: 2, latitude: 50)],
                from: place("A", latitude: 48, id: identifier), to: place("B", latitude: 50)
            )
            #expect(progress.phase == .unavailable, "\(identifier)")
            #expect(progress.stops.isEmpty)
        }
    }

    private func progress(_ stops: [StopTime], from: RailPlace, to: RailPlace) -> RailJourneyProgress {
        let trip = TrainTrip(
            id: RailIdentifier(rawValue: "eu:transitous:train"), source: "transitous", serviceDate: departure,
            operatorName: "Rail", product: "Eurostar", headsign: "Brussels", stopTimes: stops,
            capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: false,
                hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop)
        )
        return RailJourneyProgress(trip: trip, referenceDate: departure, boardingPlace: from, alightingPlace: to)
    }

    private func stop(_ native: String, sequence: Int, country: String = "FR", latitude: Double, id: String? = nil) -> StopTime {
        StopTime(station: Station(
            id: RailIdentifier(rawValue: id ?? "eu:transitous:\(native)"), names: [LocalizedStationName(native)],
            location: GeoCoordinate(latitude: latitude, longitude: 2), countryCode: country
        ), sequence: sequence, scheduledArrival: departure.addingTimeInterval(Double(sequence - 1) * 60),
        scheduledDeparture: departure.addingTimeInterval(Double(sequence - 1) * 60))
    }

    private func place(_ native: String, country: String = "FR", latitude: Double, id: String? = nil) -> RailPlace {
        RailPlace(id: RailIdentifier(rawValue: id ?? "rail:transitous:station:\(encoded("\(native)\u{1f}\(country)\u{1f}\u{1f}"))"),
                  kind: .station, displayName: native, context: "", countryCode: country,
                  timeZoneIdentifier: "Europe/Paris", location: GeoCoordinate(latitude: latitude, longitude: 2),
                  eligibleModes: ["highSpeedRail"], attributions: [])
    }

    private func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
