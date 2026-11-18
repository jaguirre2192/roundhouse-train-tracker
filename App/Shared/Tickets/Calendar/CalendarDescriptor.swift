import Foundation

/// Calendar metadata needed to choose sources without exposing EventKit objects to views.
struct CalendarDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
}
