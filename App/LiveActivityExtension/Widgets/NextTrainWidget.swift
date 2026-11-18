import SwiftUI
import TrainTrackerCore
import WidgetKit

/// "When and where is my next train, and is it on time?" on the Home Screen and Lock Screen.
struct NextTrainWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: NextTrainProvider()) { entry in
            NextTrainWidgetFamilyView(entry: entry)
        }
        .configurationDisplayName("Next Train")
        .description("Your next tracked train: when it leaves, where to board, and whether it is on time.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

struct NextTrainEntry: TimelineEntry {
    enum Source: Equatable {
        /// Read from the app's snapshot.
        case live
        /// The widget gallery: realistic, and labelled as a sample.
        case sample
        /// The first frame before data loads; drawn redacted.
        case placeholder
    }

    let date: Date
    let snapshot: WidgetTripSnapshot?
    let source: Source

    var display: WidgetDisplay { WidgetDisplay(snapshot: snapshot, at: date) }

    /// Rank the widget higher in Smart Stacks around departure and while underway.
    var relevance: TimelineEntryRelevance? {
        guard case let .train(train, _) = display else { return nil }
        switch WidgetTrainPhase(train: train, at: date) {
        case .upcoming(departureSoon: true), .underway, .cancelled: return TimelineEntryRelevance(score: 1)
        case .upcoming, .arrived: return TimelineEntryRelevance(score: 0.3)
        }
    }
}

struct NextTrainProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextTrainEntry {
        NextTrainEntry(date: .now, snapshot: NextTrainWidgetSamples.gallery(at: .now), source: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NextTrainEntry) -> Void) {
        let now = Date.now
        if context.isPreview {
            completion(NextTrainEntry(date: now, snapshot: NextTrainWidgetSamples.gallery(at: now), source: .sample))
        } else {
            completion(NextTrainEntry(date: now, snapshot: WidgetSnapshotStore.shared.load(), source: .live))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NextTrainEntry>) -> Void) {
        let now = Date.now
        let snapshot = WidgetSnapshotStore.shared.load()
        // Known future moments flip phase, next stop and freshness wording without the app.
        let keyDates = [now] + (snapshot?.timelineDates(after: now) ?? [])
        // The countdown reads in minutes, so it needs an entry on each one while it shows.
        let dates = Array(Set(keyDates + Self.countdownTicks(snapshot: snapshot, from: now))).sorted()
        let entries = dates.map { NextTrainEntry(date: $0, snapshot: snapshot, source: .live) }
        // The app reloads timelines when trains change; this only re-reads the same file.
        let policy: TimelineReloadPolicy = dates.count > 1 ? .atEnd : .after(now.addingTimeInterval(6 * 3_600))
        completion(Timeline(entries: entries, policy: policy))
    }
}

extension NextTrainProvider {
    /// One date a minute, from now until the train's next moment (it leaves, or it arrives),
    /// while that moment is within the ninety minutes the countdown covers.
    static func countdownTicks(snapshot: WidgetTripSnapshot?, from now: Date) -> [Date] {
        guard case let .train(train, _) = WidgetDisplay(snapshot: snapshot, at: now),
              let anchor = WidgetTrainPresentation(train: train, at: now).anchorDate else { return [] }
        let remaining = anchor.timeIntervalSince(now)
        guard remaining > 0, remaining <= 90 * 60 else { return [] }
        // Aligned to the anchor, so each entry lands as the minute count changes.
        return stride(from: remaining.truncatingRemainder(dividingBy: 60), through: remaining, by: 60)
            .map { now.addingTimeInterval($0) }
            .filter { $0 > now }
    }
}

/// Picks the family's composition. Families are composed separately, not scaled.
struct NextTrainWidgetFamilyView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextTrainEntry

    var body: some View {
        NextTrainWidgetView(entry: entry, family: family)
    }
}

struct NextTrainWidgetView: View {
    let entry: NextTrainEntry
    let family: WidgetFamily

    var body: some View {
        content
            .redacted(reason: entry.source == .placeholder ? .placeholder : [])
            .widgetURL(url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            NextTrainMediumView(entry: entry)
                .containerBackground(for: .widget) { NextTrainTicketBackground() }
        case .accessoryInline:
            NextTrainInlineView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            NextTrainRectangularView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryCircular:
            NextTrainCircularView(entry: entry)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        default:
            NextTrainSmallView(entry: entry)
                .containerBackground(for: .widget) { NextTrainTicketBackground() }
        }
    }

    private var url: URL? {
        entry.display.primary?.deepLinkURL ?? NextTrainWidgetLinks.addJourney
    }
}

enum NextTrainWidgetLinks {
    /// Opens Add Journey. The app needs a `traintracker://add-journey` route; until it has
    /// one, the URL falls through harmlessly and the app simply opens.
    static let addJourney = URL(string: "traintracker://add-journey")
}
