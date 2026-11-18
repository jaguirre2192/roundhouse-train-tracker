import Foundation
import Testing
@testable import TrainTrackerCore

@Suite struct TicketPurchaseJourneyTests {
    let departure = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func preservesScheduledTimesInsteadOfDelayedTimesOrSearchCutoff() throws {
        let journey = try TicketPurchaseJourney(outbound: option(), returnOption: nil)
        let leg = try #require(journey.outbound.legs.first)
        #expect(leg.departure == departure)
        #expect(leg.arrival == departure.addingTimeInterval(3_600))
        #expect(leg.departureTimeZone == "America/New_York")
        #expect(journey.canSearch(at: departure.addingTimeInterval(-1)))
        #expect(!journey.canSearch(at: departure))
        #expect(!journey.summary.contains("secret-token"))
    }

    @Test func returnIsPreservedAndInvalidReturnRejectsWholeSelection() throws {
        let returning = option(id: "return", offset: 86_400, reversed: true)
        let journey = try TicketPurchaseJourney(outbound: option(), returnOption: returning)
        #expect(journey.returnDirection?.legs.first?.origin == "New York Penn Station")
        #expect(journey.returnDirection?.legs.first?.departure == departure.addingTimeInterval(86_400))
        #expect(throws: TicketPurchaseJourney.ValidationError.self) {
            try TicketPurchaseJourney(outbound: option(), returnOption: option(country: "CA"))
        }
    }

    @Test func rejectsMissingScheduleEvenWhenRealtimeExists() {
        #expect(throws: TicketPurchaseJourney.ValidationError.self) {
            try TicketPurchaseJourney(outbound: option(missingSchedule: true), returnOption: nil)
        }
    }

    @Test func rejectsCancelledUnknownTimezoneAndUnsupportedOperator() {
        for value in [option(cancelled: true), option(zone: "Unknown/Station"),
                      option(operatorName: "Brightline"), option(country: "CA")] {
            #expect(throws: TicketPurchaseJourney.ValidationError.self) {
                try TicketPurchaseJourney(outbound: value, returnOption: nil)
            }
        }
    }

    @Test func currentTrackingAvailabilityDoesNotImplyTicketAvailability() throws {
        let journey = try TicketPurchaseJourney(outbound: option(trackable: false), returnOption: nil)
        #expect(journey.outbound.legs.count == 1)
        #expect(journey.retailerURL.absoluteString == "https://www.omio.com/trains/united-states")
        #expect(URLComponents(url: journey.retailerURL, resolvingAgainstBaseURL: false)?.query == nil)
    }

    @Test func roundTripCannotReturnBeforeOutboundArrival() {
        #expect(throws: TicketPurchaseJourney.ValidationError.self) {
            try TicketPurchaseJourney(outbound: option(), returnOption: option(id: "return", reversed: true))
        }
    }

    @Test func localDateUsesStationTimezoneAcrossMidnightAndDST() {
        let instant = ISO8601DateFormatter().date(from: "2026-11-02T04:30:00Z")!
        let value = TicketPurchaseJourney.localDate(instant, timeZone: "America/New_York")
        #expect(value.contains("Nov 1, 2026"))
        #expect(value.contains("11:30"))
        #expect(value.contains("EST"))
    }

    @Test func roundTripsSurviveEncodingWithoutTrackingTokens() throws {
        let original = try TicketPurchaseJourney(outbound: option(), returnOption: option(id: "return", offset: 86_400, reversed: true))
        let data = try JSONEncoder().encode(original)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret-token"))
        #expect(try JSONDecoder().decode(TicketPurchaseJourney.self, from: data) == original)
    }

    private func option(id: String = "outbound", offset: TimeInterval = 0, reversed: Bool = false,
                        country: String = "US", zone: String = "America/New_York", operatorName: String = "Amtrak",
                        cancelled: Bool = false, missingSchedule: Bool = false, trackable: Bool = true) -> JourneyOption {
        let from = place(reversed ? "NYP" : "WAS", country: country, zone: zone)
        let to = place(reversed ? "WAS" : "NYP", country: country, zone: zone)
        let date = departure.addingTimeInterval(offset)
        let rail = RailJourneySegment(id: id, tripID: nil, serviceDate: date, operatorName: operatorName,
            product: "Northeast Regional", trainNumber: "176", trainName: nil,
            from: JourneyCall(place: from, city: nil, scheduledArrival: nil,
                scheduledDeparture: missingSchedule ? nil : date, expectedArrival: nil,
                expectedDeparture: date.addingTimeInterval(1_800), plannedPlatform: nil, expectedPlatform: nil, isCancelled: false),
            to: JourneyCall(place: to, city: nil, scheduledArrival: date.addingTimeInterval(3_600),
                scheduledDeparture: nil, expectedArrival: date.addingTimeInterval(5_400), expectedDeparture: nil,
                plannedPlatform: nil, expectedPlatform: nil, isCancelled: false),
            intermediateCalls: [], isCancelled: cancelled, isRealtime: true, isTrackable: trackable, untrackableReason: nil)
        return JourneyOption(id: id, fingerprint: id, startTime: date.addingTimeInterval(-600),
            endTime: date.addingTimeInterval(6_000), duration: 6_600, transferCount: 0, segments: [.rail(rail)],
            badges: [], trackability: .init(trackableRailSegments: trackable ? 1 : 0, totalRailSegments: 1),
            realtimeFreshness: nil, attributions: [], trackingToken: "secret-token")
    }

    private func place(_ code: String, country: String, zone: String) -> RailPlace {
        RailPlace(id: .init(rawValue: code), kind: .station,
            displayName: code == "WAS" ? "Washington Union Station" : "New York Penn Station", context: "",
            countryCode: country, timeZoneIdentifier: zone,
            location: .init(latitude: 38, longitude: -77), eligibleModes: ["rail"], attributions: [])
    }
}
