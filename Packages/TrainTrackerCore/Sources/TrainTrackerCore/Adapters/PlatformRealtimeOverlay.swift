import Foundation

public struct PlatformUpdate: Identifiable, Codable, Hashable, Sendable {
    public let tripID: RailIdentifier
    public let stopSequence: Int
    public let stationID: RailIdentifier?
    public let plannedPlatform: String?
    public let expectedPlatform: String
    public let observedAt: Date
    public let source: String

    public init(
        tripID: RailIdentifier,
        stopSequence: Int,
        stationID: RailIdentifier? = nil,
        plannedPlatform: String? = nil,
        expectedPlatform: String,
        observedAt: Date,
        source: String
    ) {
        self.tripID = tripID
        self.stopSequence = stopSequence
        self.stationID = stationID
        self.plannedPlatform = plannedPlatform
        self.expectedPlatform = expectedPlatform
        self.observedAt = observedAt
        self.source = source
    }

    public var id: String { "\(tripID.rawValue)#\(stopSequence)#\(source)" }
}

public protocol PlatformRealtimeOverlay: Sendable {
    var sourceName: String { get }
    var supportedCountryCodes: Set<String> { get }

    func platformUpdates(for trip: TrainTrip) async throws -> [PlatformUpdate]
}

public actor RealtimeTripEnricher {
    private let overlays: [any PlatformRealtimeOverlay]

    public init(overlays: [any PlatformRealtimeOverlay]) {
        self.overlays = overlays
    }

    public func enrich(_ trip: TrainTrip) async -> TrainTrip {
        let countryCodes = Set(trip.stopTimes.map { $0.station.countryCode.uppercased() })
        let applicable = overlays.filter { !$0.supportedCountryCodes.isDisjoint(with: countryCodes) }

        var updates: [PlatformUpdate] = []
        await withTaskGroup(of: [PlatformUpdate].self) { group in
            for overlay in applicable {
                group.addTask {
                    (try? await overlay.platformUpdates(for: trip)) ?? []
                }
            }
            for await values in group {
                updates.append(contentsOf: values)
            }
        }

        guard !updates.isEmpty else { return trip }
        let bySequence = Dictionary(grouping: updates.filter { $0.tripID == trip.id }, by: \.stopSequence)
        let enrichedStops = trip.stopTimes.map { stop in
            let matching = bySequence[stop.sequence]?.filter { $0.stationID == nil || $0.stationID == stop.station.id }
            guard let update = matching?.max(by: { $0.observedAt < $1.observedAt }) else { return stop }
            return StopTime(
                station: stop.station,
                sequence: stop.sequence,
                scheduledArrival: stop.scheduledArrival,
                scheduledDeparture: stop.scheduledDeparture,
                expectedArrival: stop.expectedArrival,
                expectedDeparture: stop.expectedDeparture,
                plannedPlatform: stop.plannedPlatform ?? update.plannedPlatform,
                expectedPlatform: update.expectedPlatform,
                platformForecast: stop.platformForecast,
                platformKind: stop.platformKind,
                platformSource: update.source, platformObservedAt: update.observedAt,
                isCancelled: stop.isCancelled,
                isPassed: stop.isPassed, passageObservedAt: stop.passageObservedAt,
                arrivalObservedAt: stop.arrivalObservedAt
            )
        }

        return TrainTrip(
            id: trip.id,
            source: trip.source,
            serviceDate: trip.serviceDate,
            operatorName: trip.operatorName,
            product: trip.product,
            headsign: trip.headsign,
            stopTimes: enrichedStops,
            routeGeometry: trip.routeGeometry,
            positions: trip.positions,
            alerts: trip.alerts,
            capabilities: RealtimeCapabilities(
                hasPositions: trip.capabilities.hasPositions,
                hasPlatforms: true,
                hasRealtimeDelays: trip.capabilities.hasRealtimeDelays,
                hasAlerts: trip.capabilities.hasAlerts,
                granularity: trip.capabilities.granularity
            ),
            sourceFetchedAt: trip.sourceFetchedAt
        )
    }
}
