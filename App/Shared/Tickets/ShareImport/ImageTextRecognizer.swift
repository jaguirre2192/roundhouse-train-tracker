import Foundation
import UIKit
import Vision

/// Seam over on-device text recognition so `ShareImportParser` can be tested without invoking
/// Vision (which needs a real decodable image and isn't deterministic to assert against in unit
/// tests). Production code uses `VisionImageTextRecognizer`; tests inject a fake that returns
/// canned text to verify it flows through the same route heuristics as every other source kind.
protocol ImageTextRecognizing: Sendable {
    func recognizeText(in payload: Data) async throws -> String?
}

/// Bounded, on-device, cancellable OCR for a shared image — nothing here ever leaves the device.
/// Recognition is capped at `timeout`; if it hasn't produced a result by then, the underlying
/// Vision request is cancelled and `nil` is treated as "no text found" by the caller.
struct VisionImageTextRecognizer: ImageTextRecognizing {
    private let timeout: Duration

    init(timeout: Duration = .seconds(8)) {
        self.timeout = timeout
    }

    func recognizeText(in payload: Data) async throws -> String? {
        guard let cgImage = UIImage(data: payload)?.cgImage else { return nil }
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await Self.recognize(cgImage) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return nil }
            return first
        }
    }

    private static let maxCharacters = 4000

    /// `VNRequest` isn't `Sendable`, but `cancel()` is documented as safe to call from any thread
    /// — this box exists only to hand that one call across the `onCancel` boundary below.
    private final class CancellableRequestBox: @unchecked Sendable {
        private let request: VNRequest
        init(_ request: VNRequest) { self.request = request }
        func cancel() { request.cancel() }
    }

    private static func recognize(_ cgImage: CGImage) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let cancellationBox = CancellableRequestBox(request)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let combined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return combined.isEmpty ? nil : String(combined.prefix(maxCharacters))
        } onCancel: {
            cancellationBox.cancel()
        }
    }
}
