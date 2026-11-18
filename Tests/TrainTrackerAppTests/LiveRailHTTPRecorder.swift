import Foundation
import TrainTrackerCore
@testable import TrainTracker

/// Observes actual URLSession traffic. Response bodies never leave this actor: evidence keeps
/// only public rail metadata, never tracking tokens, credentials, request bodies or cookies.
actor LiveRailHTTPRecorder: HTTPClient {
    struct SnapshotResponse: Sendable {
        let status: Int
        let tripID: String?
    }
    private let transport = URLSessionHTTPClient()
    private(set) var snapshotResponses: [SnapshotResponse] = []
    private var summaries: [String] = []
    var evidence: String { summaries.joined(separator: "\n") }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await sendAndRecord(request)
        guard response.statusCode == 429,
              let retry = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init),
              retry >= 0, retry <= 60 else { return response }
        summaries.append("Respecting Retry-After=\(retry)s; retrying the same request once")
        try await Task.sleep(for: .seconds(retry + 0.1))
        return try await sendAndRecord(request)
    }

    private func sendAndRecord(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        let path = request.url?.path ?? "unknown"
        summaries.append("HTTP \(path): \(response.statusCode)")
        let body = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        if path == "/v1/trips/snapshot" {
            let tripID = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "id" }?.value
            snapshotResponses.append(SnapshotResponse(status: response.statusCode, tripID: tripID))
            if let body { summaries.append(Self.snapshotEvidence(body)) }
        } else if path == "/v1/journeys/search", let body {
            summaries.append("Search generatedAt=\(Self.text(body["generatedAt"])) expiresAt=\(Self.text(body["expiresAt"]))")
            for option in (body["options"] as? [[String: Any]] ?? []).prefix(6) {
                for segment in option["segments"] as? [[String: Any]] ?? [] {
                    guard let rail = segment["rail"] as? [String: Any] else { continue }
                    summaries.append("Search rail id=\(Self.text(rail["tripId"])) operator=\(Self.text(rail["operatorName"])) trainNumber=\(Self.text(rail["trainNumber"])) isRealtime=\(Self.text(rail["isRealtime"]))")
                }
            }
        } else if path == "/v1/journey-plans/resolve", let body {
            for direction in body["directions"] as? [[String: Any]] ?? [] {
                for segment in direction["segments"] as? [[String: Any]] ?? [] {
                    if let trip = segment["trip"] as? [String: Any] { summaries.append(Self.snapshotEvidence(trip)) }
                }
            }
        }
        return response
    }

    private static func snapshotEvidence(_ snapshot: [String: Any]) -> String {
        let stops = snapshot["stops"] as? [[String: Any]] ?? []
        let positions = snapshot["positions"] as? [[String: Any]] ?? []
        var estimateCount = 0
        var changedEstimateCount = 0
        for stop in stops {
            for event in ["Arrival", "Departure"] {
                if let expected = stop["expected" + event] as? String {
                    estimateCount += 1
                    if let scheduled = stop["scheduled" + event] as? String,
                       let expectedDate = WireDate.date(from: expected), let scheduledDate = WireDate.date(from: scheduled),
                       expectedDate != scheduledDate { changedEstimateCount += 1 }
                }
            }
        }
        let platforms = stops.compactMap { stop -> String? in
            guard stop["expectedPlatform"] is String || stop["platformObservedAt"] is String else { return nil }
            return "\(text(stop["stationName"])) planned=\(text(stop["plannedPlatform"])) expected=\(text(stop["expectedPlatform"])) source=\(text(stop["platformSource"])) observedAt=\(text(stop["platformObservedAt"]))"
        }
        let observations = positions.prefix(4).map {
            "source=\(text($0["source"])) provider=\(text($0["provider"])) asOf=\(text($0["asOf"]))"
        }
        let freshness = (snapshot["fetchedAt"] as? String).flatMap(WireDate.date).map {
            String(format: "%.1fs", max(0, Date.now.timeIntervalSince($0)))
        } ?? "unknown"
        return """
        Snapshot id=\(text(snapshot["id"])) source=\(text(snapshot["source"])) serviceDate=\(text(snapshot["serviceDate"])) fetchedAt=\(text(snapshot["fetchedAt"])) fetchAge=\(freshness)
        Stops=\(stops.count), expectedEvents=\(estimateCount), estimatesDifferentFromSchedule=\(changedEstimateCount), platformObservations=\(stops.filter { $0["platformObservedAt"] is String }.count), positions=\(positions.count)
        Platforms: \(platforms.prefix(12).joined(separator: "; "))
        Position observations: \(observations.joined(separator: "; "))
        Evidence rule: fetchedAt shows a successful fetch; equal expected/scheduled times alone do not prove live observations. Provider isRealtime and observation timestamps are reported separately.
        """
    }

    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return "absent"
    }
}
