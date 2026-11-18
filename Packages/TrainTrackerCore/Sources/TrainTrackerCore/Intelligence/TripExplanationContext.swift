import Foundation

/// Provider-sourced facts that an explanation engine may summarize without
/// becoming an authority for live rail state.
public struct TripExplanationContext: Codable, Hashable, Sendable {
    public let tripID: RailIdentifier
    public let providerSource: String
    public let serviceDate: Date
    public let operatorName: String
    public let product: String
    public let headsign: String
    public let stops: [TripExplanationStopFact]
    public let alerts: [TripExplanationAlertFact]

    public init(
        tripID: RailIdentifier,
        providerSource: String,
        serviceDate: Date,
        operatorName: String,
        product: String,
        headsign: String,
        stops: [TripExplanationStopFact],
        alerts: [TripExplanationAlertFact]
    ) {
        self.tripID = tripID
        self.providerSource = providerSource
        self.serviceDate = serviceDate
        self.operatorName = operatorName
        self.product = product
        self.headsign = headsign
        self.stops = stops
        self.alerts = alerts
    }
}

public struct TripExplanationStopFact: Codable, Hashable, Sendable {
    public let stationID: RailIdentifier
    public let stationName: String
    public let sequence: Int
    public let scheduledArrival: Date?
    public let scheduledDeparture: Date?
    public let expectedArrival: Date?
    public let expectedDeparture: Date?
    public let plannedPlatform: String?
    public let expectedPlatform: String?
    public let isCancelled: Bool
    public let isPassed: Bool
}

public struct TripExplanationAlertFact: Codable, Hashable, Sendable {
    public let alertID: RailIdentifier
    public let severity: AlertSeverity
    public let cause: String?
    public let message: String
    public let validFrom: Date?
    public let validUntil: Date?
}

public enum TripExplanationAbstention: String, Codable, Hashable, Sendable {
    case missingProviderSource
    case insufficientRouteFacts
}

public enum TripExplanationReadiness: Codable, Hashable, Sendable {
    case ready(TripExplanationContext)
    case abstain(TripExplanationAbstention)
}

public enum TripExplanationContextBuilder {
    public static func readiness(
        for trip: TrainTrip,
        at date: Date = .now
    ) -> TripExplanationReadiness {
        let providerSource = normalized(trip.source)
        guard let providerSource else {
            return .abstain(.missingProviderSource)
        }

        guard trip.stopTimes.count >= 2 else {
            return .abstain(.insufficientRouteFacts)
        }

        let stops = trip.stopTimes.map { stop in
            TripExplanationStopFact(
                stationID: stop.station.id,
                stationName: stop.station.displayName,
                sequence: stop.sequence,
                scheduledArrival: stop.scheduledArrival,
                scheduledDeparture: stop.scheduledDeparture,
                expectedArrival: stop.expectedArrival,
                expectedDeparture: stop.expectedDeparture,
                plannedPlatform: normalized(stop.plannedPlatform),
                expectedPlatform: normalized(stop.expectedPlatform),
                isCancelled: stop.isCancelled,
                isPassed: stop.isPassed
            )
        }
        let alerts = trip.alerts.compactMap { alert -> TripExplanationAlertFact? in
            guard alert.validFrom.map({ $0 <= date }) ?? true,
                  alert.validUntil.map({ date <= $0 }) ?? true,
                  let message = normalized(alert.message) else {
                return nil
            }
            return TripExplanationAlertFact(
                alertID: alert.id,
                severity: alert.severity,
                cause: normalized(alert.cause),
                message: message,
                validFrom: alert.validFrom,
                validUntil: alert.validUntil
            )
        }

        return .ready(TripExplanationContext(
            tripID: trip.id,
            providerSource: providerSource,
            serviceDate: trip.serviceDate,
            operatorName: normalized(trip.operatorName) ?? "",
            product: normalized(trip.product) ?? "",
            headsign: normalized(trip.headsign) ?? "",
            stops: stops,
            alerts: alerts
        ))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// A future model adapter can implement this protocol. The returned prose is
/// explanatory only; callers must continue rendering `TrainTrip` as the source
/// of truth for operational status.
public protocol TripExplanationGenerating: Sendable {
    func explanation(for context: TripExplanationContext) async throws -> String
}
