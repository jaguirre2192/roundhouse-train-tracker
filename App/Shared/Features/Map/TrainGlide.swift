import MapKit
import TrainTrackerCore

/// A route line measured along its length, so a train can be placed a given distance down it.
struct RoutePath {
    let points: [MKMapPoint]
    /// Meters travelled from the start at each point.
    let cumulative: [CLLocationDistance]

    init?(coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1 else { return nil }
        let points = coordinates.map { MKMapPoint($0) }
        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(points.count)
        for index in 1..<points.count {
            cumulative.append(cumulative[index - 1] + points[index - 1].distance(to: points[index]))
        }
        guard let length = cumulative.last, length > 0 else { return nil }
        self.points = points
        self.cumulative = cumulative
    }

    var length: CLLocationDistance { cumulative[cumulative.count - 1] }

    /// The closest place on the line: how far along it is, and how far off the line the
    /// coordinate sits.
    func projection(of coordinate: CLLocationCoordinate2D) -> (distance: CLLocationDistance, offset: CLLocationDistance) {
        let target = MKMapPoint(coordinate)
        var best = (distance: 0.0, offsetSquared: Double.greatestFiniteMagnitude, point: points[0])
        for index in 0..<(points.count - 1) {
            let start = points[index], end = points[index + 1]
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : min(1, max(0, ((target.x - start.x) * dx + (target.y - start.y) * dy) / lengthSquared))
            let candidate = MKMapPoint(x: start.x + t * dx, y: start.y + t * dy)
            let ox = target.x - candidate.x, oy = target.y - candidate.y
            let offsetSquared = ox * ox + oy * oy
            if offsetSquared < best.offsetSquared {
                best = (cumulative[index] + (cumulative[index + 1] - cumulative[index]) * t, offsetSquared, candidate)
            }
        }
        return (best.distance, best.point.distance(to: target))
    }

    func coordinate(at distance: CLLocationDistance) -> CLLocationCoordinate2D {
        let (index, t) = segment(at: distance)
        let start = points[index], end = points[index + 1]
        return MKMapPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t).coordinate
    }

    /// The line between two distances along it, ends included.
    func slice(from: CLLocationDistance, to: CLLocationDistance) -> [CLLocationCoordinate2D] {
        let lower = min(max(from, 0), length), upper = min(max(to, lower), length)
        guard upper > lower else { return [] }
        let first = segment(at: lower).index + 1
        let last = segment(at: upper).index
        var result = [coordinate(at: lower)]
        if first <= last { result.append(contentsOf: points[first...last].map(\.coordinate)) }
        result.append(coordinate(at: upper))
        return result
    }

    /// The segment holding a distance and how far through that segment it is.
    private func segment(at distance: CLLocationDistance) -> (index: Int, t: Double) {
        let clamped = min(max(distance, 0), length)
        var low = 0, high = cumulative.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if cumulative[middle] <= clamped { low = middle } else { high = middle }
        }
        let span = cumulative[low + 1] - cumulative[low]
        return (low, span == 0 ? 0 : (clamped - cumulative[low]) / span)
    }
}

/// Where a train most likely is between two reported positions.
///
/// The operator reports a position every minute or so. Between reports the train keeps moving,
/// so the map carries it along the track at the pace its next arrival implies. The estimate
/// never passes the next stop, stops after three minutes without a new report, and holds at a
/// station until the train is due out. It is an estimate and the map says so.
struct TrainGlide {
    let path: RoutePath
    /// How far along the route the reported position is.
    let fixDistance: CLLocationDistance
    let reportedCoordinate: CLLocationCoordinate2D
    /// When the train is taken to start moving from there: the report, or a later departure.
    let startDate: Date
    /// Meters per second along the route.
    let speed: CLLocationDistance
    /// The next stop; the estimate holds just short of it.
    let limitDistance: CLLocationDistance

    static let longestExtrapolation: TimeInterval = 180
    /// A report further than this from the route line is not on this line; it is shown as is.
    static let largestOffset: CLLocationDistance = 2_000
    static let fastestTrain: CLLocationDistance = 70

    init?(trip: TrainTrip, position: VehiclePosition, path: RoutePath, referenceDate: Date = .now) {
        guard !trip.isCancelled,
              position == TripRouteMapGeometry.confirmedPosition(in: trip, referenceDate: referenceDate) else { return nil }
        let fix = path.projection(of: position.coordinate.mapCoordinate)
        guard fix.offset <= Self.largestOffset else { return nil }
        guard let next = TripRouteMapGeometry.observedNextStop(in: trip, referenceDate: referenceDate) else { return nil }
        let nextDistance = path.projection(of: next.station.mapCoordinate).distance
        guard let arrival = next.expectedArrival ?? next.scheduledArrival ?? next.expectedDeparture ?? next.scheduledDeparture else { return nil }

        // Standing at a station it has yet to leave: wait for the departure.
        var start = position.asOf
        if let dwelling = trip.stopTimes.first(where: { $0.id == next.id }),
           MKMapPoint(dwelling.station.mapCoordinate).distance(to: MKMapPoint(position.coordinate.mapCoordinate)) < 400,
           let departure = dwelling.expectedDeparture ?? dwelling.scheduledDeparture, departure > start {
            start = departure
        }

        let remaining = nextDistance - fix.distance
        let time = arrival.timeIntervalSince(start)
        self.path = path
        self.fixDistance = fix.distance
        self.reportedCoordinate = position.coordinate.mapCoordinate
        self.startDate = start
        self.limitDistance = max(nextDistance - 40, fix.distance)
        self.speed = remaining > 50 && time > 20 ? min(remaining / time, Self.fastestTrain) : 0
    }

    func distance(at date: Date) -> CLLocationDistance {
        let elapsed = min(max(date.timeIntervalSince(startDate), 0), Self.longestExtrapolation)
        return min(fixDistance + speed * elapsed, limitDistance)
    }

    func coordinate(at date: Date) -> CLLocationCoordinate2D {
        isEstimated(at: date) ? path.coordinate(at: distance(at: date)) : reportedCoordinate
    }

    /// Every forward extrapolation is labeled as estimated, including for accessibility.
    func isEstimated(at date: Date) -> Bool {
        distance(at: date) > fixDistance
    }
}
