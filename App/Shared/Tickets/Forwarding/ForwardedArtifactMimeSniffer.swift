import Foundation

/// The forwarding backend sets an honest `Content-Type` on every artifact response, so that
/// header is trusted first. This only exists as a safety net for a missing or generic header —
/// never as the primary way of deciding a downloaded artifact's type before showing it.
enum ForwardedArtifactMimeSniffer {
    static func mimeType(headerValue: String?, data: Data) -> String {
        if let headerValue, isKnownDocumentType(headerValue) { return headerValue }
        return sniff(data) ?? headerValue ?? "application/octet-stream"
    }

    private static func isKnownDocumentType(_ value: String) -> Bool {
        value == "application/pdf" || value.hasPrefix("image/")
    }

    private static func sniff(_ data: Data) -> String? {
        if data.starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        return nil
    }
}
