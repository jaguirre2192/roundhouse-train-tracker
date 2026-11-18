import SwiftUI
import TrainTrackerCore

/// Pages turned with the Digital Crown: each train the rider still has ahead is a glance,
/// followed by its wake switch. Usually that is two pages. The clock drives it, so the
/// countdown, the handover to the next train and "Saved" all happen on time without a new
/// message from the phone.
struct WatchRootView: View {
    @Environment(WatchStore.self) private var store
    @State private var selection: Page?

    private enum Page: Hashable {
        case glance(String)
        case wake(String)
    }

    var body: some View {
        TimelineView(.periodic(from: Self.topOfMinute, by: 30)) { timeline in
            content(at: timeline.date)
        }
        .background(.black)
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        if let payload = store.payload {
            switch WidgetDisplay(snapshot: payload.snapshot, at: date) {
            case .empty:
                WatchEmptyView(kind: .noTrain)
            case let .ended(train):
                WatchTrainPage(train: train, date: date, hasEnded: true)
            case let .train(primary, _):
                let open = Self.openTrains(in: payload.snapshot, at: date)
                // A stale, unconfirmed journey remains the display's fallback after
                // bounded retention. Preserve that page instead of showing an empty pager.
                pages(open.isEmpty ? [primary] : open, at: date)
            }
        } else {
            WatchEmptyView(kind: .waitingForPhone)
        }
    }

    private func pages(_ trains: [WidgetTripSnapshot.Train], at date: Date) -> some View {
        TabView(selection: $selection) {
            ForEach(trains) { train in
                WatchTrainPage(train: train, date: date)
                    .tag(Optional(Page.glance(train.id)))
                if WatchWakePage.isOffered(for: train, at: date) {
                    WatchWakePage(train: train)
                        .tag(Optional(Page.wake(train.id)))
                }
            }
        }
        .tabViewStyle(.verticalPage)
        .onAppear {
            if store.opensOnWake, selection == nil, let first = trains.first { selection = .wake(first.id) }
        }
    }

    /// The trains `WidgetDisplay` chooses its answer from, in the same order.
    private static func openTrains(in snapshot: WidgetTripSnapshot, at date: Date) -> [WidgetTripSnapshot.Train] {
        snapshot.trains.filter { $0.departure != nil && $0.arrival != nil && !WidgetTrainPhase.isFinished($0, at: date) }
    }

    /// Ticks land on the minute and the half minute, when a whole-minute time changes.
    private static var topOfMinute: Date {
        Date(timeIntervalSinceReferenceDate: (Date.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

/// Nothing to count down to: either the phone has no train, or it has not said anything yet.
struct WatchEmptyView: View {
    enum Kind {
        case noTrain
        case waitingForPhone
    }

    let kind: Kind

    var body: some View {
        VStack(spacing: 6) {
            Image(TrainTrackerSymbol.train)
                .font(.title2.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .scenePadding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch kind {
        case .noTrain: "No train right now"
        case .waitingForPhone: "Waiting for iPhone"
        }
    }

    private var detail: String {
        switch kind {
        case .noTrain: "Add a journey on your iPhone"
        case .waitingForPhone: "Open Roundhouse on your iPhone"
        }
    }
}
