import MapKit
import TrainTrackerCore

enum TripRouteMapGeometry {
    static func latestPosition(in trip: TrainTrip, referenceDate: Date = .now) -> VehiclePosition? {
        RailJourneyEvidence.latestRealPosition(in: trip, at: referenceDate, maximumAge: .greatestFiniteMagnitude)
            .flatMap { $0.asOf <= referenceDate ? $0 : nil }
    }

    /// Only the trip's own fresh, unambiguous route match can establish movement on this map.
    static func confirmedPosition(in trip: TrainTrip, referenceDate: Date = .now) -> VehiclePosition? {
        let evidence = RailJourneyEvidence(trip: trip, referenceDate: referenceDate)
        guard evidence.basis == .vehiclePosition, let position = evidence.position,
              position.asOf <= referenceDate else { return nil }
        return position
    }

    static func observedNextStop(in trip: TrainTrip, referenceDate: Date = .now) -> StopTime? {
        let progress = confirmedProgress(in: trip, referenceDate: referenceDate)
        return trip.stopTimes.first { $0.id == progress.focusStopID }
    }

    static func nearbyNextStop(
        in trip: TrainTrip, position: VehiclePosition?, referenceDate: Date = .now
    ) -> StopTime? {
        guard let position, position == confirmedPosition(in: trip, referenceDate: referenceDate),
              let nextStop = observedNextStop(in: trip, referenceDate: referenceDate) else { return nil }
        let positionPoint = MKMapPoint(position.coordinate.mapCoordinate)
        let nextStopPoint = MKMapPoint(nextStop.station.mapCoordinate)
        return positionPoint.distance(to: nextStopPoint) <= collisionThreshold(for: trip) ? nextStop : nil
    }

    static func passedRoute(
        in trip: TrainTrip, position: VehiclePosition?, referenceDate: Date = .now
    ) -> [CLLocationCoordinate2D] {
        if let exact = exactRoute(in: trip) {
            return split(exact, at: progressCoordinate(in: trip, position: position, referenceDate: referenceDate)).passed
        }
        return fallbackRoutes(in: trip, position: position, referenceDate: referenceDate).passed
    }

    static func upcomingRoute(
        in trip: TrainTrip, position: VehiclePosition?, referenceDate: Date = .now
    ) -> [CLLocationCoordinate2D] {
        if let exact = exactRoute(in: trip) {
            return split(exact, at: progressCoordinate(in: trip, position: position, referenceDate: referenceDate)).upcoming
        }
        return fallbackRoutes(in: trip, position: position, referenceDate: referenceDate).upcoming
    }

    /// The confirmed trail ends at an observation, never at the animated marker. Without track
    /// geometry the curve through the stops remains schematic, including its confirmed part.
    static func drawnRoutes(
        in trip: TrainTrip, position: VehiclePosition?, referenceDate: Date = .now
    ) -> (passed: [CLLocationCoordinate2D], upcoming: [CLLocationCoordinate2D], isSchematic: Bool) {
        if let exact = exactRoute(in: trip) {
            let routes = split(exact, at: progressCoordinate(in: trip, position: position, referenceDate: referenceDate))
            return (routes.passed, routes.upcoming, false)
        }
        let fallback = fallbackRoutes(in: trip, position: position, referenceDate: referenceDate)
        guard !fallback.passed.isEmpty, !fallback.upcoming.isEmpty else {
            return (smoothCurve(through: fallback.passed).points, smoothCurve(through: fallback.upcoming).points, true)
        }
        // The halves share their joining point; curving them as one line leaves no kink there.
        let joined = fallback.passed + fallback.upcoming.dropFirst()
        let curve = smoothCurve(through: joined)
        let split = curve.vertexIndices[fallback.passed.count - 1]
        return (Array(curve.points[...split]), Array(curve.points[split...]), true)
    }

    /// A centripetal Catmull-Rom curve through every coordinate, which bends without the loops
    /// and overshoot a uniform spline makes between unevenly spaced stops. `vertexIndices` gives
    /// each input coordinate's place in the output.
    static func smoothCurve(
        through coordinates: [CLLocationCoordinate2D],
        samplesPerSegment: Int = 16
    ) -> (points: [CLLocationCoordinate2D], vertexIndices: [Int]) {
        guard coordinates.count > 2, samplesPerSegment > 1 else {
            return (coordinates, Array(coordinates.indices))
        }
        let mapPoints = coordinates.map { MKMapPoint($0) }
        func mirrored(_ point: MKMapPoint, across pivot: MKMapPoint) -> MKMapPoint {
            MKMapPoint(x: 2 * pivot.x - point.x, y: 2 * pivot.y - point.y)
        }
        func knot(_ start: MKMapPoint, _ end: MKMapPoint) -> Double {
            max(hypot(end.x - start.x, end.y - start.y).squareRoot(), 1e-6)
        }
        func blend(_ start: MKMapPoint, _ end: MKMapPoint, _ fraction: Double) -> MKMapPoint {
            MKMapPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        }

        var points = [coordinates[0]]
        var vertexIndices = [0]
        for index in 0..<(mapPoints.count - 1) {
            let p1 = mapPoints[index]
            let p2 = mapPoints[index + 1]
            let p0 = index > 0 ? mapPoints[index - 1] : mirrored(p2, across: p1)
            let p3 = index + 2 < mapPoints.count ? mapPoints[index + 2] : mirrored(p1, across: p2)
            let t0 = 0.0
            let t1 = t0 + knot(p0, p1)
            let t2 = t1 + knot(p1, p2)
            let t3 = t2 + knot(p2, p3)
            for step in 1..<samplesPerSegment {
                let t = t1 + (t2 - t1) * Double(step) / Double(samplesPerSegment)
                let a1 = blend(p0, p1, (t - t0) / (t1 - t0))
                let a2 = blend(p1, p2, (t - t1) / (t2 - t1))
                let a3 = blend(p2, p3, (t - t2) / (t3 - t2))
                let b1 = blend(a1, a2, (t - t0) / (t2 - t0))
                let b2 = blend(a2, a3, (t - t1) / (t3 - t1))
                points.append(blend(b1, b2, (t - t1) / (t2 - t1)).coordinate)
            }
            points.append(coordinates[index + 1])
            vertexIndices.append(points.count - 1)
        }
        return (points, vertexIndices)
    }

    static func routeCoordinates(in trip: TrainTrip) -> [CLLocationCoordinate2D] {
        exactRoute(in: trip) ?? trip.stopTimes.map(\.station.mapCoordinate)
    }

    private static func fallbackRoutes(
        in trip: TrainTrip, position: VehiclePosition?, referenceDate: Date
    ) -> (passed: [CLLocationCoordinate2D], upcoming: [CLLocationCoordinate2D]) {
        let stops = trip.stopTimes
        guard !stops.isEmpty else { return ([], []) }
        if let position, position == confirmedPosition(in: trip, referenceDate: referenceDate) {
            let progress = confirmedProgress(in: trip, referenceDate: referenceDate)
            let coordinate = position.coordinate.mapCoordinate
            let passed = stops.filter { progress.passedStopIDs.contains($0.id) }.map(\.station.mapCoordinate)
            let nextIndex = stops.firstIndex { $0.id == progress.focusStopID } ?? stops.count
            return (passed + [coordinate], [coordinate] + stops.dropFirst(nextIndex).map(\.station.mapCoordinate))
        }
        guard let lastPassedIndex = stops.lastIndex(where: { confirmedPassage($0, at: referenceDate) }) else {
            return ([], stops.map(\.station.mapCoordinate))
        }
        return (stops.prefix(lastPassedIndex + 1).map(\.station.mapCoordinate),
                stops.suffix(from: lastPassedIndex).map(\.station.mapCoordinate))
    }

    /// The provider's track geometry, when it supplied one.
    static func exactRouteCoordinates(in trip: TrainTrip) -> [CLLocationCoordinate2D]? {
        exactRoute(in: trip)
    }

    private static func exactRoute(in trip: TrainTrip) -> [CLLocationCoordinate2D]? {
        guard let geometry = trip.routeGeometry else { return nil }
        let coordinates = geometry.coordinates.map(\.mapCoordinate)
        return coordinates.count > 1 ? coordinates : nil
    }

    private static func progressCoordinate(
        in trip: TrainTrip, position: VehiclePosition?, referenceDate: Date
    ) -> CLLocationCoordinate2D? {
        if let position, position == confirmedPosition(in: trip, referenceDate: referenceDate) {
            return position.coordinate.mapCoordinate
        }
        return trip.stopTimes.last { confirmedPassage($0, at: referenceDate) }?.station.mapCoordinate
    }

    private static func confirmedPassage(_ stop: StopTime, at date: Date) -> Bool {
        !stop.isCancelled && stop.hasConfirmedPassage(at: date)
            && stop.passageObservedAt.map { $0 <= date } == true
    }

    /// Core permits small provider clock skew. A map trail does not advance to a future fix
    /// or report, so rejected GPS falls back only to explicit, already observed stop reports.
    private static func confirmedProgress(
        in trip: TrainTrip, referenceDate: Date
    ) -> (passedStopIDs: Set<String>, focusStopID: String?) {
        let evidence = RailJourneyEvidence(trip: trip, referenceDate: referenceDate)
        if evidence.basis == .vehiclePosition, let position = evidence.position, position.asOf <= referenceDate {
            return (evidence.confirmedPassedStopIDs, evidence.observedFocusStopID)
        }
        let passedIDs = Set(trip.stopTimes.filter { confirmedPassage($0, at: referenceDate) }.map(\.id))
        let observed = trip.stopTimes.enumerated().compactMap { index, stop -> (Int, Date)? in
            guard !stop.isCancelled else { return nil }
            let report = [stop.arrivalObservedAt, passedIDs.contains(stop.id) ? stop.passageObservedAt : nil]
                .compactMap { $0 }.filter { $0 <= referenceDate && referenceDate.timeIntervalSince($0) <= 300 }.max()
            return report.map { (index, $0) }
        }.max { $0.1 < $1.1 }
        guard let observed else { return (passedIDs, nil) }
        let index = observed.0
        if passedIDs.contains(trip.stopTimes[index].id) {
            return (passedIDs, trip.stopTimes.dropFirst(index + 1).first { !$0.isCancelled }?.id)
        }
        return (passedIDs, index == trip.stopTimes.count - 1 ? nil : trip.stopTimes[index].id)
    }

    private static func split(
        _ coordinates: [CLLocationCoordinate2D],
        at progress: CLLocationCoordinate2D?
    ) -> (passed: [CLLocationCoordinate2D], upcoming: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1 else { return ([], coordinates) }
        guard let progress else { return ([], coordinates) }

        let point = MKMapPoint(progress)
        var closestSegment = 0
        var closestPoint = MKMapPoint(coordinates[0])
        var closestDistanceSquared = Double.greatestFiniteMagnitude

        for index in 0..<(coordinates.count - 1) {
            let start = MKMapPoint(coordinates[index])
            let end = MKMapPoint(coordinates[index + 1])
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            let projection = lengthSquared == 0
                ? 0
                : min(1, max(0, ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared))
            let candidate = MKMapPoint(
                x: start.x + projection * deltaX,
                y: start.y + projection * deltaY
            )
            let distanceX = point.x - candidate.x
            let distanceY = point.y - candidate.y
            let distanceSquared = distanceX * distanceX + distanceY * distanceY
            if distanceSquared < closestDistanceSquared {
                closestDistanceSquared = distanceSquared
                closestSegment = index
                closestPoint = candidate
            }
        }

        let projected = closestPoint.coordinate
        var passed = Array(coordinates.prefix(closestSegment + 1))
        if passed.last.map({ !sameCoordinate($0, projected) }) ?? true {
            passed.append(projected)
        }
        var upcoming = [projected]
        for coordinate in coordinates.suffix(from: closestSegment + 1)
            where upcoming.last.map({ !sameCoordinate($0, coordinate) }) ?? true {
            upcoming.append(coordinate)
        }
        return (passed, upcoming)
    }

    static func mapStops(in trip: TrainTrip, nearbyNextStop: StopTime?, referenceDate: Date = .now) -> [MapStop] {
        guard let origin = trip.stopTimes.first, let destination = trip.stopTimes.last else { return [] }
        var candidates = [MapStop(stop: origin, role: .origin)]

        let progress = confirmedProgress(in: trip, referenceDate: referenceDate)
        if let passed = trip.stopTimes.last(where: { progress.passedStopIDs.contains($0.id) }), passed.id != origin.id {
            candidates.append(MapStop(stop: passed, role: .passed))
        }
        if let next = trip.stopTimes.first(where: { $0.id == progress.focusStopID }),
           next.id != origin.id,
           next.id != nearbyNextStop?.id {
            candidates.append(MapStop(stop: next, role: .next))
        }
        if destination.id != origin.id {
            candidates.append(MapStop(stop: destination, role: .destination))
        }

        var stationIDs = Set<String>()
        return candidates.filter { stationIDs.insert($0.stop.id).inserted }
    }

    static func region(for trip: TrainTrip) -> MKCoordinateRegion {
        let coordinates = routeCoordinates(in: trip)
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
                span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 55)
            )
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minimumLatitude = latitudes.min() ?? first.latitude
        let maximumLatitude = latitudes.max() ?? first.latitude
        let minimumLongitude = longitudes.min() ?? first.longitude
        let maximumLongitude = longitudes.max() ?? first.longitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (maximumLatitude + minimumLatitude) / 2,
                longitude: (maximumLongitude + minimumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maximumLatitude - minimumLatitude) * 1.35, 0.2),
                longitudeDelta: max((maximumLongitude - minimumLongitude) * 1.35, 0.2)
            )
        )
    }

    private static func sameCoordinate(
        _ left: CLLocationCoordinate2D,
        _ right: CLLocationCoordinate2D
    ) -> Bool {
        abs(left.latitude - right.latitude) < 0.000_000_1
            && abs(left.longitude - right.longitude) < 0.000_000_1
    }

    private static func collisionThreshold(for trip: TrainTrip) -> CLLocationDistance {
        guard let origin = trip.stopTimes.first, let destination = trip.stopTimes.last else {
            return 2_000
        }
        let originPoint = MKMapPoint(origin.station.mapCoordinate)
        let destinationPoint = MKMapPoint(destination.station.mapCoordinate)
        let routeSpan = originPoint.distance(to: destinationPoint)
        return min(25_000, max(2_000, routeSpan * 0.08))
    }
}

extension Station {
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }
}

extension GeoCoordinate {
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
