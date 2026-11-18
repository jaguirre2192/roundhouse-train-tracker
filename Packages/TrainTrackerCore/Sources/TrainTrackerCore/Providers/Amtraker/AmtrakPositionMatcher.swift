import Foundation

/// Supplies Amtraker GPS for any Amtrak trip, including trains saved through journey search whose
/// identity comes from Transitous GTFS (for example `…_us-Amtrak_285229`). The live instance is
/// chosen by schedule, never by train number alone, so an earlier or later day's train of the
/// same number can't supply the position.
public protocol AmtrakPositionProviding: Sendable {
    func livePosition(matching trip: TrainTrip) async throws -> VehiclePosition?
}

public enum AmtrakPositionMatcher {
    /// Positions older than this are not attached; the map would otherwise show a far-off train.
    public static let maximumAge: TimeInterval = 60 * 60
    static let scheduleTolerance: TimeInterval = 90

    public static func isAmtrak(_ trip: TrainTrip) -> Bool {
        trip.source == "amtraker"
            || trip.operatorName.localizedCaseInsensitiveContains("amtrak")
            || trip.id.rawValue.localizedCaseInsensitiveContains("us-amtrak")
    }

    /// "2120" from an Amtraker trainID ("2120-15") or from a product such as "Acela 2120" / "2120".
    public static func trainNumber(for trip: TrainTrip) -> String? {
        if trip.source == "amtraker", let native = trip.id.nativeID ?? Optional(trip.id.rawValue),
           let number = native.split(separator: "-").first, number.allSatisfy(\.isNumber) {
            return String(number)
        }
        let tokens = trip.product.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.last(where: { $0.allSatisfy(\.isNumber) && (1...4).contains($0.count) }).map(String.init)
    }

    /// The single Amtraker instance that calls at the same station at the same scheduled time as
    /// the saved trip. An Amtraker trainID ("2120-15") repeats every month, so even an exact ID
    /// must be corroborated by absolute schedule time at a corresponding station.
    static func matchingTrain(for trip: TrainTrip, in candidates: [AmtrakerTrainDTO]) -> AmtrakerTrainDTO? {
        if trip.source == "amtraker", let native = trip.id.nativeID,
           let exact = candidates.first(where: { $0.trainID == native }),
           corroborates(trip, exact) {
            return exact
        }
        let matches = candidates.filter { corroborates(trip, $0) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// True when some saved stop and some Amtraker stop are the same station (by code, or by
    /// name when no code is known) with scheduled times within the tolerance.
    static func corroborates(_ trip: TrainTrip, _ candidate: AmtrakerTrainDTO) -> Bool {
        trip.stopTimes.contains { saved in
            let savedTimes = [saved.scheduledDeparture, saved.scheduledArrival].compactMap { $0 }
            guard !savedTimes.isEmpty else { return false }
            return candidate.stations.contains { stop in
                guard stationsCorrespond(saved.station, stop) else { return false }
                return [RailDateParser.parse(stop.schDep), RailDateParser.parse(stop.schArr)].compactMap { $0 }.contains { time in
                    savedTimes.contains { abs($0.timeIntervalSince(time)) <= scheduleTolerance }
                }
            }
        }
    }

    static func stationsCorrespond(_ station: Station, _ stop: AmtrakerStopDTO) -> Bool {
        let code = stop.code.uppercased()
        if let savedCode = amtrakCode(for: station) {
            return savedCode == code
        }
        let saved = normalizedName(station.displayName)
        let other = normalizedName(stop.name)
        guard !saved.isEmpty, !other.isEmpty else { return false }
        return saved == other || saved.hasPrefix(other + " ") || other.hasPrefix(saved + " ")
    }

    /// "WAS" from `us:amtraker:WAS`, `us:transitous:us-Amtrak_WAS` or a source-native code.
    public static func amtrakCode(for station: Station) -> String? {
        let candidates = [station.codes[.sourceNative], station.id.nativeID, station.id.rawValue].compactMap { $0 }
        for value in candidates {
            let tail = value.split(whereSeparator: { $0 == "_" || $0 == ":" }).last.map(String.init) ?? value
            if tail.count == 3, tail.allSatisfy({ $0.isLetter && $0.isUppercase }) { return tail }
        }
        return nil
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "station" }
            .joined(separator: " ")
    }

    static func position(for trip: TrainTrip, in candidates: [AmtrakerTrainDTO], now: Date) -> VehiclePosition? {
        guard let train = matchingTrain(for: trip, in: candidates),
              let position = AmtrakerMapper.position(train, now: now),
              now.timeIntervalSince(position.asOf) <= maximumAge else { return nil }
        return position
    }
}

extension AmtrakerAdapter: AmtrakPositionProviding {
    public func livePosition(matching trip: TrainTrip) async throws -> VehiclePosition? {
        guard AmtrakPositionMatcher.isAmtrak(trip), let number = AmtrakPositionMatcher.trainNumber(for: trip) else {
            return nil
        }
        let candidates = try await trainInstances(number: number)
        return AmtrakPositionMatcher.position(for: trip, in: candidates, now: currentDate())
    }
}
