import Foundation

public actor RenfePlatformOverlay: PlatformRealtimeOverlay {
    public nonisolated let sourceName = "Renfe GTFS-RT"
    public nonisolated let supportedCountryCodes: Set<String> = ["ES"]

    private let client: any HTTPClient
    private let feedURL: URL

    public init(
        client: any HTTPClient = URLSessionHTTPClient(),
        feedURL: URL = URL(string: "https://gtfsrt.renfe.com/vehicle_positions.json")!
    ) {
        self.client = client
        self.feedURL = feedURL
    }

    public func platformUpdates(for trip: TrainTrip) async throws -> [PlatformUpdate] {
        var request = URLRequest(url: feedURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TrainTracker/0.1", forHTTPHeaderField: "User-Agent")
        let feed = try await client.decoded(RenfeVehicleFeedDTO.self, from: request)
        let tripNumbers = numericTokens(in: trip.product)

        return feed.entity.compactMap { entity in
            guard let platform = platform(from: entity.vehicle.vehicle?.label),
                  matches(entity.vehicle, trip: trip, tripNumbers: tripNumbers),
                  let stop = matchingStop(entity.vehicle.stopId, in: trip)
            else { return nil }
            let observedAt = TimeInterval(entity.vehicle.timestamp ?? feed.header.timestamp)
                .map(Date.init(timeIntervalSince1970:)) ?? .now
            return PlatformUpdate(
                tripID: trip.id,
                stopSequence: stop.sequence,
                stationID: stop.station.id,
                plannedPlatform: stop.plannedPlatform,
                expectedPlatform: platform,
                observedAt: observedAt,
                source: sourceName
            )
        }
    }

    private func matches(
        _ vehicle: RenfeVehicleDTO,
        trip: TrainTrip,
        tripNumbers: Set<String>
    ) -> Bool {
        let providerTripID = vehicle.trip.tripId
        if trip.id.nativeID?.contains(providerTripID) == true || providerTripID.contains(trip.id.nativeID ?? "∅") {
            return true
        }
        let vehicleText = [vehicle.vehicle?.id, vehicle.vehicle?.label].compactMap { $0 }.joined(separator: " ")
        return !tripNumbers.isEmpty && !tripNumbers.isDisjoint(with: numericTokens(in: vehicleText))
    }

    private func matchingStop(_ stopID: String?, in trip: TrainTrip) -> StopTime? {
        if let stopID,
           let exact = trip.stopTimes.first(where: { $0.station.id.nativeID?.contains(stopID) == true }) {
            return exact
        }
        return trip.stopTimes.first { !$0.isPassed && $0.station.countryCode.uppercased() == "ES" }
    }

    private func platform(from label: String?) -> String? {
        guard let label,
              let marker = label.range(of: "PLATF.("),
              let end = label[marker.upperBound...].firstIndex(of: ")")
        else { return nil }
        let value = label[marker.upperBound ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func numericTokens(in value: String) -> Set<String> {
        Set(value.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
    }
}

private struct RenfeVehicleFeedDTO: Decodable, Sendable {
    let header: RenfeHeaderDTO
    let entity: [RenfeEntityDTO]
}

private struct RenfeHeaderDTO: Decodable, Sendable {
    let timestamp: String
}

private struct RenfeEntityDTO: Decodable, Sendable {
    let vehicle: RenfeVehicleDTO
}

private struct RenfeVehicleDTO: Decodable, Sendable {
    let trip: RenfeTripReferenceDTO
    let timestamp: String?
    let stopId: String?
    let vehicle: RenfeVehicleReferenceDTO?
}

private struct RenfeTripReferenceDTO: Decodable, Sendable {
    let tripId: String
}

private struct RenfeVehicleReferenceDTO: Decodable, Sendable {
    let id: String?
    let label: String?
}
