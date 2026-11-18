import SwiftUI

/// The journey's quiet actions, at the foot of its details: pass it on, or stop following it.
struct JourneyActionRow: View {
    let shareURL: URL?
    let shareSubject: String
    var share: (() -> Void)? = nil
    let stopTracking: () -> Void

    var body: some View {
        JourneyActionLayout(spacing: TrainTrackerSpacing.space12) {
            buttons
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    @ViewBuilder
    private var buttons: some View {
        if let shareURL {
            ShareLink(
                item: shareURL,
                subject: Text(shareSubject),
                message: Text("Add this train to Roundhouse. Ticket and passenger details are not shared.")
            ) {
                actionLabel("Share Trip", symbol: "square.and.arrow.up")
            }
        } else if let share {
            Button(action: share) {
                actionLabel("Share Trip", symbol: "square.and.arrow.up")
            }
        }
        Button(role: .destructive, action: stopTracking) {
            actionLabel("Stop Tracking", symbol: "trash")
        }
        .accessibilityIdentifier("stopTrackingFromJourney")
    }

    private func actionLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// Equal columns only when each can hold the widest native button at its natural size.
/// Otherwise the same controls stack; labels can grow vertically at accessibility sizes.
private struct JourneyActionLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measure = measurement(width: proposal.width, subviews: subviews)
        return CGSize(width: measure.width, height: measure.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measure = measurement(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            let height = measure.sizes[index].height
            view.place(at: CGPoint(x: bounds.minX + (measure.horizontal ? CGFloat(index) * (measure.column + spacing) : 0), y: y),
                       anchor: .topLeading, proposal: ProposedViewSize(width: measure.column, height: measure.horizontal ? measure.height : height))
            if !measure.horizontal { y += height + spacing }
        }
    }

    private func measurement(width: CGFloat?, subviews: Subviews) -> (width: CGFloat, height: CGFloat, column: CGFloat, horizontal: Bool, sizes: [CGSize]) {
        let count = subviews.count
        guard count > 0 else { return (0, 0, 0, true, []) }
        let gap = CGFloat(count - 1) * spacing
        let naturalWidth = (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) * CGFloat(count) + gap
        let width = width ?? naturalWidth
        let horizontal = naturalWidth <= width
        let column = horizontal ? max(0, (width - gap) / CGFloat(count)) : width
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)) }
        let height = horizontal ? (sizes.map(\.height).max() ?? 0) : sizes.map(\.height).reduce(0, +) + gap
        return (width, height, column, horizontal, sizes)
    }
}
