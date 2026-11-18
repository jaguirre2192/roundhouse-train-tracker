import Foundation

public struct RouteGeometry: Codable, Hashable, Sendable {
    public struct Segment: Codable, Hashable, Sendable {
        public let encodedPolyline: String
        public let precision: Int
        public let pointCount: Int

        public init(encodedPolyline: String, precision: Int, pointCount: Int) {
            self.encodedPolyline = encodedPolyline
            self.precision = precision
            self.pointCount = pointCount
        }

        public var coordinates: [GeoCoordinate] {
            guard !encodedPolyline.isEmpty,
                  (0...7).contains(precision),
                  pointCount > 1,
                  pointCount <= 100_000
            else { return [] }

            let bytes = Array(encodedPolyline.utf8)
            let scale = pow(10.0, Double(precision))
            var index = 0
            var latitude = 0
            var longitude = 0
            var values: [GeoCoordinate] = []
            values.reserveCapacity(min(pointCount, 10_000))

            while index < bytes.count && values.count < pointCount {
                guard let latitudeDelta = Self.decodeComponent(bytes, index: &index),
                      let longitudeDelta = Self.decodeComponent(bytes, index: &index)
                else { return [] }
                let (nextLatitude, latitudeOverflow) = latitude.addingReportingOverflow(latitudeDelta)
                let (nextLongitude, longitudeOverflow) = longitude.addingReportingOverflow(longitudeDelta)
                guard !latitudeOverflow, !longitudeOverflow else { return [] }
                latitude = nextLatitude
                longitude = nextLongitude
                let coordinate = GeoCoordinate(
                    latitude: Double(latitude) / scale,
                    longitude: Double(longitude) / scale
                )
                guard (-90...90).contains(coordinate.latitude),
                      (-180...180).contains(coordinate.longitude)
                else { return [] }
                values.append(coordinate)
            }

            guard index == bytes.count, values.count == pointCount else { return [] }
            return values
        }

        private static func decodeComponent(_ bytes: [UInt8], index: inout Int) -> Int? {
            var result = 0
            var shift = 0

            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard (0...63).contains(byte), shift <= 30 else { return nil }
                result |= (byte & 0x1F) << shift
                if byte < 0x20 {
                    return (result & 1) == 1 ? ~(result >> 1) : result >> 1
                }
                shift += 5
            }
            return nil
        }
    }

    public let source: String
    public let segments: [Segment]

    public init(source: String, segments: [Segment]) {
        self.source = source
        self.segments = segments
    }

    public var coordinates: [GeoCoordinate] {
        var result: [GeoCoordinate] = []
        for segment in segments {
            for coordinate in segment.coordinates where result.last != coordinate {
                result.append(coordinate)
            }
        }
        return result
    }
}
