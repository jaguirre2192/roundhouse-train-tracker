import Foundation

enum RailRequestBudget {
    // Transitous: 20 seconds; platform/alert and position phases: 3 seconds each.
    // Leave 4 seconds for transport and backend response processing per attempt.
    static let timeoutInterval: TimeInterval = 30
}
