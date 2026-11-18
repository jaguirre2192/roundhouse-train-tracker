import TrainTrackerCore
import XCTest
@testable import TrainTracker

/// Creates only loopback boards. Uses the current Amtrak station board and the native
/// snapshot and sharing clients, then opens exactly the address a recipient would get.
@MainActor
final class LiveMeetTrainWorkerTests: XCTestCase {
    func testNativeSharingClientOpensRealIntermediateArrivalOnLocalWorker() async throws {
        guard let configuredPort = ProcessInfo.processInfo.environment["TRAIN_TRACKER_MEET_WORKER_PORT"] else {
            throw XCTSkip("Set TRAIN_TRACKER_MEET_WORKER_PORT to exercise a running local Worker.")
        }
        let port = try XCTUnwrap(UInt16(configuredPort), "The local Worker requires a numeric TCP port.")
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let client = TripSnapshotBackendClient(baseURL: base)
        let now = Date.now
        let board = try await client.board(stationID: .init(rawValue: "us:amtraker:JAX"), at: now,
                                           direction: .arrivals, source: .unitedStates)
        let sharing = TripSharingClient(baseURL: base)
        for row in board where !row.stopTime.isCancelled {
            let train = try await client.trip(id: row.tripID, serviceDate: row.serviceDate, source: .unitedStates)
            guard let stop = train.stopTimes.dropFirst().dropLast().first(where: {
                AmtrakPositionMatcher.amtrakCode(for: $0.station) == "JAX" && !$0.hasConfirmedArrival(at: now)
            }) else { continue }
            let link = try await sharing.createArrivalBoard(for: train, stop: stop, zone: TimeZone(identifier: "America/New_York"),
                                                           note: "Meet at the station clock.")
            XCTAssertEqual(link.url.host, base.host)
            XCTAssertEqual(link.url.port, base.port)
            let (page, http) = try await URLSession.shared.data(from: link.url)
            XCTAssertEqual((http as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Meet my train"))
            var read = URLRequest(url: base.appending(path: "v1/arrival-boards/status"))
            read.httpMethod = "POST"
            read.setValue("application/json", forHTTPHeaderField: "Content-Type")
            read.httpBody = try JSONEncoder().encode(["token": try XCTUnwrap(link.url.fragment)])
            let (bytes, response) = try await URLSession.shared.data(for: read)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let content = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(content["station"] as? String, stop.station.displayName)
            XCTAssertEqual(content["service"] as? String, train.product)
            XCTAssertEqual(content["note"] as? String, "Meet at the station clock.")
            XCTAssertTrue(Set(content.keys).isDisjoint(with: ["stops", "positions", "trip", "ticket", "coordinate", "seat"]))
            let proof = XCTAttachment(string: "\(train.product), selected \(stop.station.displayName) of \(train.stopTimes.count) calls. Native creation and recipient page/status succeeded. Arrival basis: \(content["basis"] ?? "unknown").")
            proof.name = "Local native arrival-board round trip"
            proof.lifetime = .keepAlways
            add(proof)
            return
        }
        throw XCTSkip("The current public board has no eligible intermediate Jacksonville arrival.")
    }
}
