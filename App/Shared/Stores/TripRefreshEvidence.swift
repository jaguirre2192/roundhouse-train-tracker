import Foundation

/// Records a successful check; retained timetables keep their original source fetch date.
/// Restoring saved evidence does not check the train again.
struct TripRefreshEvidence {
    private(set) var lastSuccessfulCheck: Date?
    private(set) var lastRefreshFailed = false
    var changes: TripChangeJournal

    init(lastSuccessfulCheck: Date? = nil, changes: TripChangeJournal = TripChangeJournal()) {
        self.lastSuccessfulCheck = lastSuccessfulCheck
        self.changes = changes
    }

    mutating func recordSuccess(at date: Date) {
        lastSuccessfulCheck = date
        lastRefreshFailed = false
    }

    mutating func recordFailure() {
        lastRefreshFailed = true
    }
}
