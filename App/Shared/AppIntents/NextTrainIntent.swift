import AppIntents
import Foundation
import TrainTrackerCore

/// "When's my next train?" answered by Siri without opening the app, from the same snapshot
/// the Next Train widget shows, so the two never disagree.
struct NextTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Train"
    static let description = IntentDescription(
        "Tells you when your next tracked train leaves or arrives, with any delay and its track or platform."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runtime = TrainJourneyRuntime.shared
        runtime.retryArchiveAvailability()
        let library = runtime.library
        let now = Date.now
        let snapshot = WidgetSnapshotPublisher.snapshot(
            trips: library.trips, plans: runtime.planLibrary?.plans ?? [], at: now,
            lastSuccessfulCheck: { library.lastSuccessfulCheck(for: $0) },
            lastRefreshFailed: { library.lastRefreshFailed(for: $0) }
        )
        let answer = NextTrainAnswer(snapshot: snapshot, at: now)
        return .result(dialog: IntentDialog(stringLiteral: answer.text))
    }
}

/// The spoken sentence, kept apart from the intent so it can be tested.
struct NextTrainAnswer {
    let text: String

    init(snapshot: WidgetTripSnapshot?, at date: Date, clock: WidgetClock = WidgetClock()) {
        guard let train = WidgetDisplay(snapshot: snapshot, at: date).primary else {
            text = "You have no upcoming trains in Roundhouse. Add a journey and I can tell you when it leaves."
            return
        }
        let presentation = WidgetTrainPresentation(train: train, at: date, clock: clock)
        let station = presentation.anchor == .departs ? train.boarding?.name : train.alighting?.name
        let place = station.map { " \(presentation.anchor == .departs ? "from" : "at") \($0)" } ?? ""
        let zone = presentation.anchorZone.map { " \($0)" } ?? ""
        let time = presentation.anchorTimeText + zone

        var sentence: String
        switch presentation.status {
        case .cancelled:
            sentence = "\(train.serviceName)\(place) at \(time) is canceled. Check the operator’s travel advice."
        case .arrived:
            sentence = "\(train.serviceName) arrived\(place) at \(time)."
        case let .delayed(minutes):
            sentence = "\(train.serviceName) \(verb(presentation))\(place) at \(time), about \(minutes) minutes late."
        case .onTime:
            sentence = "\(train.serviceName) \(verb(presentation))\(place) at \(time), on time."
        case .scheduled:
            sentence = "\(train.serviceName) is scheduled to \(presentation.anchor == .departs ? "leave" : "arrive")\(place) at \(time)."
        }
        if let platform = presentation.platformValue {
            sentence += " \(presentation.platformNoun) \(platform)."
        }
        // Saved details are said to be saved, as on the ticket.
        if !presentation.isRecentlyChecked, presentation.status != .arrived {
            sentence += " That’s from saved details; open Roundhouse to check live times."
        }
        text = sentence
    }
}

private func verb(_ presentation: WidgetTrainPresentation) -> String {
    presentation.anchor == .departs ? "leaves" : "arrives"
}
