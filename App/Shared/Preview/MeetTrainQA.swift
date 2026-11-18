#if DEBUG
import Foundation
import TrainTrackerCore

/// Native interaction fixture. Its separately verified Worker contract receives only the
/// middle station. The system share sheet may open, but this local sample is never sent.
enum MeetTrainQA {
    static func sharingClient(enabled: Bool) -> TripSharingClient {
        guard enabled else { return TripSharingClient() }
        return TripSharingClient(baseURL: URL(string: "https://roundhouse.test"), client: Transport())
    }

    private actor Transport: HTTPClient {
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            if request.url?.path == "/v1/shares" { return HTTPResponse(data: Data(), statusCode: 503) }
            guard request.url?.path == "/v1/arrival-boards", request.httpMethod == "POST",
                  let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["stationId"] as? String == "us:amtraker:BAL", body["sequence"] as? Int == 2,
                  body["timeZone"] as? String == "America/New_York", body["note"] as? String == "By the clock" else {
                return HTTPResponse(data: Data(), statusCode: 422)
            }
            let expiry = ISO8601DateFormatter().string(from: .now.addingTimeInterval(12 * 3_600))
            let bodyOut = ["url": "https://roundhouse.test/meet#" + String(repeating: "x", count: 43), "expiresAt": expiry]
            return HTTPResponse(data: try JSONEncoder().encode(bodyOut), statusCode: 201)
        }
    }
}
#endif
