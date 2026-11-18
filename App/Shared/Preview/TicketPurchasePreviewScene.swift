#if DEBUG
import SwiftUI
import TrainTrackerCore

struct TicketPurchasePreviewScene: View {
    @State private var store: JourneySearchStore
    private let fixture: TicketPurchasePreviewFixture
    let entry: Bool

    init(planLibrary: JourneyPlanLibrary, entry: Bool) {
        let fixture = TicketPurchasePreviewFixture()
        self.fixture = fixture
        self.entry = entry
        _store = State(initialValue: JourneySearchStore(client: TicketPurchasePreviewClient(fixture: fixture),
            planTracker: planLibrary,
            form: JourneySearchFormState(origin: fixture.origin, destination: fixture.destination,
                outboundTime: fixture.departure, returnEnabled: true,
                returnTime: fixture.departure.addingTimeInterval(86_400))))
    }

    var body: some View {
        NavigationStack {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-TicketPurchasePreviewSaved") {
                    ScrollView { TicketPurchaseSavedSection().padding() }
                        .navigationTitle("Ticket searches")
                } else if entry {
                    RoundTripReviewView(store: store)
                        .task {
                            guard store.phase == .editing else { return }
                            store.searchOutbound()
                            for _ in 0..<100 {
                                if store.phase == .showingOutbound { break }
                                await Task.yield()
                            }
                            store.selectOutbound(fixture.outbound)
                            for _ in 0..<100 {
                                if store.phase == .showingReturn { break }
                                await Task.yield()
                            }
                            store.selectReturn(fixture.returning)
                        }
                } else {
                    TicketPurchaseView(journey: try! TicketPurchaseJourney(outbound: fixture.outbound, returnOption: fixture.returning))
                }
            }
        }
    }
}

struct TicketPurchasePreviewFixture: Sendable {
    let departure: Date
    var origin: RailPlace { place("WAS", name: "Washington Union Station") }
    var destination: RailPlace { place("NYP", name: "New York Penn Station") }
    var outbound: JourneyOption { option(returning: false) }
    var returning: JourneyOption { option(returning: true) }

    init(departure: Date? = nil) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        self.departure = departure ?? calendar.date(bySettingHour: 10, minute: 0, second: 0,
            of: calendar.date(byAdding: .day, value: 1, to: .now)!)!
    }

    private func option(returning: Bool) -> JourneyOption {
        let id = returning ? "ticket-preview-return" : "ticket-preview-outbound"
        let start = departure.addingTimeInterval(returning ? 86_400 + 6 * 3_600 : 0)
        let end = start.addingTimeInterval(3 * 3_600 + 20 * 60)
        let rail = RailJourneySegment(id: id, tripID: nil, serviceDate: start, operatorName: "Amtrak",
            product: "Northeast Regional", trainNumber: returning ? "177" : "176", trainName: nil,
            from: .init(place: returning ? destination : origin, city: nil, scheduledArrival: nil,
                scheduledDeparture: start, expectedArrival: nil, expectedDeparture: start.addingTimeInterval(600),
                plannedPlatform: nil, expectedPlatform: nil, isCancelled: false),
            to: .init(place: returning ? origin : destination, city: nil, scheduledArrival: end,
                scheduledDeparture: nil, expectedArrival: end.addingTimeInterval(600), expectedDeparture: nil,
                plannedPlatform: nil, expectedPlatform: nil, isCancelled: false),
            intermediateCalls: [], isCancelled: false, isRealtime: true, isTrackable: false,
            untrackableReason: "Preview tracking is unavailable")
        return .init(id: id, fingerprint: id, startTime: start, endTime: end,
            duration: end.timeIntervalSince(start), transferCount: 0, segments: [.rail(rail)], badges: [],
            trackability: .init(trackableRailSegments: 0, totalRailSegments: 1),
            realtimeFreshness: nil, attributions: [], trackingToken: "preview-not-a-real-token")
    }

    private func place(_ id: String, name: String) -> RailPlace {
        .init(id: .init(rawValue: "preview:\(id)"), kind: .station, displayName: name, context: "United States",
            countryCode: "US", timeZoneIdentifier: "America/New_York",
            location: .init(latitude: id == "WAS" ? 38.897 : 40.750, longitude: id == "WAS" ? -77.006 : -73.994),
            eligibleModes: ["rail"], attributions: [])
    }
}

private struct TicketPurchasePreviewClient: JourneySearching {
    let fixture: TicketPurchasePreviewFixture
    func searchPlaces(query: String, limit: Int) async throws -> [RailPlace] { [fixture.origin, fixture.destination] }
    func searchJourneys(criteria: JourneySearchCriteria) async throws -> JourneySearchPage {
        .init(generatedAt: .now, expiresAt: .now.addingTimeInterval(3_600),
            options: [criteria.originID == fixture.origin.id ? fixture.outbound : fixture.returning],
            previousCursor: nil, nextCursor: nil, warnings: [], attributions: [])
    }
    func resolvePlan(trackingTokens: [String]) async throws -> JourneyPlanResolution { .init(directions: []) }
}
#endif
