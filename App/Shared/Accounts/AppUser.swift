import Foundation

enum AccountProvider: String, Codable, Sendable {
    case apple
    case google

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }
}

struct AppUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let email: String?
    let displayName: String?
    let providers: [AccountProvider]

    var preferredName: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "Traveler"
    }
}
