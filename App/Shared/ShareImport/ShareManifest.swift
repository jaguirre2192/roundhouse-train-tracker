import Foundation

/// Describes a single item staged into the shared App Group container by the Share extension.
/// Deliberately minimal: no account credentials or tokens ever belong in here, since this file
/// lives in a container both the extension and the host app can read.
struct ShareManifest: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case text
        case url
        case pdf
        case image
        case emailMessage
    }

    /// Pending items older than this are treated as abandoned and purged unread.
    static let maxAge: TimeInterval = 24 * 60 * 60

    let id: UUID
    let createdAt: Date
    let kind: Kind
    let payloadFilename: String
    let suggestedFilename: String?
    let sizeBytes: Int

    func isExpired(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > Self.maxAge
    }
}

enum ShareAppGroup {
    static let identifier = "group.com.jorgeaguirre.TrainTracker"
    static let inboxDirectoryName = "ShareInbox"
}
