import Foundation

/// A timetable can encode one dwell as adjacent arrival-only and departure-only rows.
/// Combine only that representation for journey presentation; raw provider/persisted rows
/// remain untouched. Nonadjacent visits, complete repeated calls and conflicting evidence
/// remain separate, so station matching must still reject ambiguous loop endpoints.
enum RailJourneyCalls {
    static func combinedSplitCalls(in stops: [StopTime]) -> [StopTime] {
        var calls: [StopTime] = []
        var index = stops.startIndex
        while index < stops.endIndex {
            let arrival = stops[index]
            let next = index + 1
            if next < stops.endIndex, let call = combined(arrival, stops[next]) {
                calls.append(call)
                index += 2
            } else {
                calls.append(arrival)
                index += 1
            }
        }
        return calls
    }

    private static func combined(_ arrival: StopTime, _ departure: StopTime) -> StopTime? {
        guard arrival.station == departure.station,
              arrival.sequence < Int.max, departure.sequence == arrival.sequence + 1,
              let scheduledArrival = arrival.scheduledArrival,
              arrival.scheduledDeparture == nil, arrival.expectedDeparture == nil,
              let scheduledDeparture = departure.scheduledDeparture,
              departure.scheduledArrival == nil, departure.expectedArrival == nil,
              ordered(scheduledArrival, scheduledDeparture),
              ordered(arrival.expectedArrival ?? scheduledArrival,
                      departure.expectedDeparture ?? scheduledDeparture),
              compatible(arrival.plannedPlatform, departure.plannedPlatform),
              compatible(arrival.expectedPlatform, departure.expectedPlatform),
              compatible(arrival.platformForecast, departure.platformForecast),
              compatible(arrival.platformKind, departure.platformKind),
              compatible(arrival.platformSource, departure.platformSource),
              arrival.isCancelled == departure.isCancelled else { return nil }
        return StopTime(
            station: arrival.station, sequence: arrival.sequence,
            scheduledArrival: scheduledArrival, scheduledDeparture: scheduledDeparture,
            expectedArrival: arrival.expectedArrival, expectedDeparture: departure.expectedDeparture,
            plannedPlatform: departure.plannedPlatform ?? arrival.plannedPlatform,
            expectedPlatform: departure.expectedPlatform ?? arrival.expectedPlatform,
            platformForecast: departure.platformForecast ?? arrival.platformForecast,
            platformKind: departure.platformKind ?? arrival.platformKind,
            platformSource: departure.platformSource ?? arrival.platformSource,
            platformObservedAt: departure.expectedPlatform == nil
                ? arrival.platformObservedAt : departure.platformObservedAt,
            // Arrival can already be passed while the train is dwelling. Passage flags
            // must not change whether the scheduled pair denotes one physical call.
            isCancelled: arrival.isCancelled, isPassed: departure.isPassed,
            passageObservedAt: departure.passageObservedAt,
            arrivalObservedAt: arrival.arrivalObservedAt ?? departure.arrivalObservedAt
        )
    }

    private static func ordered(_ arrival: Date, _ departure: Date) -> Bool {
        arrival.timeIntervalSinceReferenceDate.isFinite
            && departure.timeIntervalSinceReferenceDate.isFinite && arrival <= departure
    }

    private static func compatible<Value: Equatable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
        lhs == nil || rhs == nil || lhs == rhs
    }
}
