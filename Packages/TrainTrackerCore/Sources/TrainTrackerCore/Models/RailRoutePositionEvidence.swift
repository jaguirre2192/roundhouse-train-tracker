import Foundation

/// Conservative projection of a matched train fix onto its route. Ambiguous loops, missing
/// station coordinates and fixes away from the route provide no stop-passage evidence.
struct RailRoutePositionEvidence {
    let passedIDs: Set<String>
    let arrived: Bool
    let focusID: String?
    let isClearlyBeforeDestination: Bool

    init?(trip: TrainTrip, stops: [StopTime], position: VehiclePosition) {
        guard stops.count >= 2, stops.allSatisfy({ Self.valid($0.station.location) }),
              let departure = stops.first.flatMap({ $0.expectedDeparture ?? $0.scheduledDeparture
                  ?? $0.expectedArrival ?? $0.scheduledArrival }),
              position.asOf >= departure else { return nil }
        let coordinates = trip.routeGeometry?.coordinates ?? trip.stopTimes.map(\.station.location)
        guard let path = Path(coordinates), let fix = path.project(position.coordinate), fix.offset <= 2_000 else { return nil }
        let projections = stops.compactMap { path.project($0.station.location) }
        guard projections.count == stops.count, projections.allSatisfy({ $0.offset <= 1_000 }),
              zip(projections, projections.dropFirst()).allSatisfy({ $1.distance - $0.distance > 100 }) else { return nil }
        var passed = Set<String>()
        for (stop, projection) in zip(stops, projections) where !stop.isCancelled {
            if fix.distance > projection.distance + 500 { passed.insert(stop.id) }
        }
        let destination = stops.last!
        isClearlyBeforeDestination = fix.distance < projections.last!.distance - 500
        // A fix at a platform can be an approach or dwell. Only being clearly beyond a
        // selected intermediate destination establishes passage; terminal arrival needs a report.
        arrived = !destination.isCancelled && passed.contains(destination.id)
        passedIDs = passed
        focusID = arrived ? nil : zip(stops, projections).first {
            !$0.0.isCancelled && $0.1.distance + 500 >= fix.distance
        }?.0.id
    }

    static func valid(_ coordinate: GeoCoordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude) && (-180...180).contains(coordinate.longitude)
            && (coordinate.latitude != 0 || coordinate.longitude != 0)
    }

    private static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let y = (b.latitude - a.latitude) * 111_195
        let x = (b.longitude - a.longitude) * 111_195 * cos((a.latitude + b.latitude) * .pi / 360)
        return hypot(x, y)
    }

    private struct Projection {
        let distance: Double
        let offset: Double
    }

    private struct Path {
        let coordinates: [GeoCoordinate]
        let cumulative: [Double]

        init?(_ coordinates: [GeoCoordinate]) {
            guard coordinates.count > 1, coordinates.allSatisfy(RailRoutePositionEvidence.valid) else { return nil }
            var cumulative = [0.0]
            for (a, b) in zip(coordinates, coordinates.dropFirst()) {
                // The local planar projection deliberately declines antimeridian crossings.
                guard abs(a.longitude - b.longitude) < 180 else { return nil }
                cumulative.append(cumulative.last! + RailRoutePositionEvidence.distance(a, b))
            }
            guard cumulative.last! > 100 else { return nil }
            self.coordinates = coordinates
            self.cumulative = cumulative
        }

        func project(_ target: GeoCoordinate) -> Projection? {
            var candidates: [Projection] = []
            for index in 0..<(coordinates.count - 1) {
                let a = coordinates[index], b = coordinates[index + 1]
                let scale = 111_195 * cos(target.latitude * .pi / 180)
                let ax = (a.longitude - target.longitude) * scale
                let ay = (a.latitude - target.latitude) * 111_195
                let dx = (b.longitude - a.longitude) * scale
                let dy = (b.latitude - a.latitude) * 111_195
                let lengthSquared = dx * dx + dy * dy
                guard lengthSquared > 0 else { continue }
                let fraction = min(1, max(0, -(ax * dx + ay * dy) / lengthSquared))
                candidates.append(Projection(
                    distance: cumulative[index] + (cumulative[index + 1] - cumulative[index]) * fraction,
                    offset: hypot(ax + fraction * dx, ay + fraction * dy)
                ))
            }
            guard let best = candidates.min(by: { $0.offset < $1.offset }) else { return nil }
            // Nearby parallel/crossing route sections cannot distinguish repeated visits.
            guard !candidates.contains(where: {
                $0.offset <= best.offset + 150 && abs($0.distance - best.distance) > 1_000
            }) else { return nil }
            return best
        }
    }
}
