import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct RailJourneySplitCallTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0.0, 1.0, 5.0])
    func complementaryCallsProvideBoardingDepartureAndAlightingArrival(dwell: Double) {
        let stops = [
            stop("before", 1, departure: -30),
            stop("A", 2, arrival: -dwell), stop("A", 3, departure: 0),
            stop("B", 4, arrival: 30), stop("B", 5, departure: 30 + dwell),
            stop("after", 6, arrival: 90),
        ]
        let progress = progress(stops)
        #expect(progress.phase == .underway)
        #expect(progress.stops.map(\.station.id) == [id("A"), id("B")])
        #expect(progress.departureDate == start)
        #expect(progress.arrivalDate == time(30))
        #expect(progress.focusStop?.station.id == id("B"))
        #expect(progress.stops.first?.scheduledArrival == time(-dwell))
        #expect(progress.stops.last?.scheduledDeparture == time(30 + dwell))
        #expect(trip(stops).stopTimes == stops, "Raw provider rows stay unchanged")
    }

    @Test func splitCallsAlsoWorkWithPlaceMatchingAndDwellFocus() {
        let stops = [stop("before", 1, departure: -30), stop("A", 2, arrival: -1),
                     stop("A", 3, departure: 0), stop("middle", 4, arrival: 10),
                     stop("middle", 5, departure: 15), stop("B", 6, arrival: 30)]
        let value = RailJourneyProgress(trip: trip(stops), referenceDate: time(12),
                                        boardingPlace: place("opaque-A", station: station("A")),
                                        alightingPlace: place("opaque-B", station: station("B")))
        #expect(value.stops.count == 3)
        #expect(value.focusStop?.station.id == id("middle"))
        #expect(value.focusStop?.scheduledArrival == time(10))
        #expect(value.nextTransitionDate == time(15))
    }

    @Test func splitCallsPreserveEstimatesAndOfficialPlatform() {
        let stops = [stop("A", 1, arrival: -1, expectedArrival: 2, platform: "3"),
                     stop("A", 2, departure: 0, expectedDeparture: 4, platform: "3"),
                     stop("B", 3, arrival: 30, expectedArrival: 34)]
        let value = progress(stops)
        #expect(value.departureDate == time(4))
        #expect(value.arrivalDate == time(34))
        #expect(value.stops.first?.expectedArrival == time(2))
        #expect(value.stops.first?.displayPlatform == "3")
        #expect(value.timingBasis == .estimated)
    }

    @Test func arrivalPassageDuringDwellDoesNotBreakTheCombinedCall() {
        let value = progress([stop("A", 1, arrival: -1, passed: true),
                              stop("A", 2, departure: 0), stop("B", 3, arrival: 30)])
        #expect(value.phase == .underway)
        #expect(value.stops.count == 2)
        #expect(value.stops.first?.isPassed == false)
    }

    @Test func separateVisitsRemainAmbiguousEvenWhenOneVisitIsSplit() {
        let routes = [
            [stop("A", 1, departure: -30), stop("middle", 2, arrival: -20),
             stop("A", 3, arrival: -1), stop("A", 4, departure: 0), stop("B", 5, arrival: 30)],
            [stop("A", 1, arrival: -31), stop("A", 2, departure: -30),
             stop("middle", 3, arrival: -20), stop("A", 4, arrival: -1),
             stop("A", 5, departure: 0), stop("B", 6, arrival: 30)],
            [stop("A", 1, arrival: -1), stop("middle", 2, arrival: 0),
             stop("A", 3, departure: 1), stop("B", 4, arrival: 30)],
        ]
        for stops in routes {
            #expect(progress(stops).phase == .unavailable)
            #expect(progress(stops).stops.isEmpty)
        }
    }

    @Test func incompleteContradictoryOrConflictingPairsRemainAmbiguous() {
        let pairs = [
            [stop("A", 1, departure: -1), stop("A", 2, arrival: 0)],
            [stop("A", 1, arrival: -1, departure: 0), stop("A", 2, arrival: 1, departure: 2)],
            [stop("A", 1, arrival: -1), stop("A", 3, departure: 0)],
            [stop("A", 1, arrival: 1), stop("A", 2, departure: 0)],
            [stop("A", 1, expectedArrival: -1), stop("A", 2, departure: 0)],
            [stop("A", 1, arrival: -1, expectedDeparture: 0), stop("A", 2, departure: 1)],
            [stop("A", 1, arrival: -1, expectedArrival: 4), stop("A", 2, departure: 0, expectedDeparture: 2)],
            [stop("A", 1, arrival: -1, platform: "1"), stop("A", 2, departure: 0, platform: "2")],
            [stop("A", 1, arrival: -1, cancelled: true), stop("A", 2, departure: 0)],
        ]
        for pair in pairs {
            let value = progress(pair + [stop("B", 4, arrival: 30)])
            #expect(value.phase == .unavailable)
            #expect(value.stops.isEmpty)
        }
    }

    private func progress(_ stops: [StopTime]) -> RailJourneyProgress {
        RailJourneyProgress(trip: trip(stops), referenceDate: time(1),
                            boardingStationID: id("A"), alightingStationID: id("B"))
    }

    private func trip(_ stops: [StopTime]) -> TrainTrip {
        TrainTrip(id: id("trip"), source: "test", serviceDate: start,
                  operatorName: "Rail", product: "Rail", headsign: "B", stopTimes: stops,
                  capabilities: RealtimeCapabilities(hasPositions: false, hasPlatforms: true,
                    hasRealtimeDelays: true, hasAlerts: false, granularity: .perStop))
    }

    private func id(_ name: String) -> RailIdentifier { RailIdentifier(rawValue: "eu:test:\(name)") }
    private func time(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
    private func station(_ name: String) -> Station {
        Station(id: id(name), names: [LocalizedStationName(name)],
                location: GeoCoordinate(latitude: name == "A" ? 47.1 : name == "B" ? 47.2 : 47.3,
                                        longitude: 9.5), countryCode: "LI")
    }
    private func place(_ name: String, station: Station) -> RailPlace {
        RailPlace(id: id(name), kind: .station, displayName: name, context: "", countryCode: "LI",
                  timeZoneIdentifier: "Europe/Vaduz", location: station.location,
                  eligibleModes: ["regionalRail"], attributions: [])
    }
    private func stop(_ name: String, _ sequence: Int, arrival: Double? = nil, departure: Double? = nil,
                      expectedArrival: Double? = nil, expectedDeparture: Double? = nil,
                      platform: String? = nil, cancelled: Bool = false, passed: Bool = false) -> StopTime {
        StopTime(station: station(name), sequence: sequence,
                 scheduledArrival: arrival.map(time), scheduledDeparture: departure.map(time),
                 expectedArrival: expectedArrival.map(time), expectedDeparture: expectedDeparture.map(time),
                 plannedPlatform: platform, isCancelled: cancelled, isPassed: passed)
    }
}
