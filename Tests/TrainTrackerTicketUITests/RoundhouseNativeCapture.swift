import XCTest

extension XCTestCase {
    @MainActor func setReviewOrientation() {
        let env = ProcessInfo.processInfo.environment
        switch env["ROUNDHOUSE_TEST_ORIENTATION"] ?? env["TEST_RUNNER_ROUNDHOUSE_TEST_ORIENTATION"] {
        case "landscapeLeft": XCUIDevice.shared.orientation = .landscapeLeft
        case "portrait": XCUIDevice.shared.orientation = .portrait
        default: break
        }
    }

    /// XCTest can capture Duo's inactive surface. The host collector targets the active
    /// display explicitly, while this handshake keeps the app on the requested screen.
    @MainActor
    func requestNativeCapture(role: String, sessionID: String? = nil) {
        let environment = ProcessInfo.processInfo.environment
        guard let id = sessionID ?? environment["ROUNDHOUSE_REVIEW_CAPTURE_ID"]
                ?? environment["TEST_RUNNER_ROUNDHOUSE_REVIEW_CAPTURE_ID"], !id.isEmpty else { return }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let request = directory.appendingPathComponent("roundhouse-capture-request.json")
        let acknowledgement = directory.appendingPathComponent("roundhouse-capture-ack.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "role": role])
            try data.write(to: request, options: .atomic)
        } catch {
            XCTFail("Cannot request native capture: \(error.localizedDescription)")
            return
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let data = try? Data(contentsOf: acknowledgement),
               let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               response["id"] as? String == id, response["role"] as? String == role {
                if let error = response["error"] as? String {
                    XCTFail("Native capture failed for \(role): \(error)")
                } else {
                    XCTAssertEqual(response["ok"] as? Bool, true, "Native capture must be acknowledged")
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Native capture timed out for \(role); start the collector with the matching capture ID")
    }
}
