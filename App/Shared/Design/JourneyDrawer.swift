import SwiftUI

/// The three heights of the journey panel that rests over the map.
enum JourneyDrawerDetent: Int, CaseIterable, Comparable {
    /// A one-line summary; the map has the screen.
    case peek
    /// The ticket and the status, with the map above.
    case half
    /// Everything about the journey.
    case full

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The heights a drawer uses, worked out once by the screen that owns it so the map can keep its
/// route clear of the panel.
struct JourneyDrawerMetrics: Equatable {
    let peek: CGFloat
    let half: CGFloat
    let full: CGFloat

    /// - Parameters:
    ///   - contentHeight: the screen's height inside its safe area, below the top bar.
    ///   - bottomInset: the bottom safe-area inset the panel extends into.
    init(contentHeight: CGFloat, bottomInset: CGFloat) {
        let total = contentHeight + bottomInset
        peek = JourneyDrawerMetrics.peekContentHeight + bottomInset
        full = max(total - 6, peek + 2)
        half = min(max(total * 0.52, peek + 1), full - 1)
    }

    /// The grabber and the summary strip.
    static let peekContentHeight: CGFloat = 78

    func height(for detent: JourneyDrawerDetent) -> CGFloat {
        switch detent {
        case .peek: peek
        case .half: half
        case .full: full
        }
    }

    /// How much of the map the panel covers while the map is still the subject.
    func mapInset(for detent: JourneyDrawerDetent) -> CGFloat {
        min(height(for: detent), half)
    }
}

/// A panel that rests over the map at three heights. It is part of the screen, not a presented
/// sheet, so the screen's own navigation, dialogs and sheets keep working while it is up.
///
/// Below full height the whole panel drags. At full height its content scrolls; the grabber
/// still drags, and pulling down past the top brings it back to half.
struct JourneyDrawer<Peek: View, Content: View>: View {
    @Binding var detent: JourneyDrawerDetent
    let metrics: JourneyDrawerMetrics
    var mood: JourneyMood = .calm
    var scrollIdentifier = "journeyDrawerScroll"
    var accessibilityTitle = "Journey details"
    var expansionHint = "Shows the ticket and stops"
    @ViewBuilder let peek: () -> Peek
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// When the journey is tied to a map, a sideways slide along the ticket's line is its.
    @Environment(JourneyMapLink.self) private var mapLink: JourneyMapLink?
    @State private var dragOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var isScrollInteracting = false

    private static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
    }

    var body: some View {
        let height = currentHeight
        let reveal = revealProgress(height: height)
        VStack(spacing: 0) {
            grabber
            ScrollView {
                content()
                    .padding(.bottom, TrainTrackerSpacing.space48)
            }
            .accessibilityIdentifier(scrollIdentifier)
            .scrollPosition($scrollPosition)
            .scrollDisabled(detent != .full)
            .scrollIndicators(detent == .full ? .automatic : .hidden)
            .onScrollPhaseChange { _, phase in isScrollInteracting = phase == .interacting }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                // Pulling down past the top of the journey hands the panel back to the map.
                if detent == .full, isScrollInteracting, offset < -64 { settle(on: .half) }
            }
            .opacity(reveal)
            .allowsHitTesting(reveal > 0.5)
            .accessibilityHidden(reveal <= 0.5)
            // An overlay, so the strip is laid out in the panel's width and can never widen it.
            .overlay(alignment: .top) {
                // A tap, not a button: the strip travels with the finger, and a button that
                // moves with a drag would fire when the drag ends.
                peek()
                    .contentShape(.rect)
                    .onTapGesture { settle(on: .half) }
                    .opacity(1 - min(reveal * 2.5, 1))
                    .allowsHitTesting(reveal < 0.2)
                    .accessibilityHidden(reveal >= 0.2)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(expansionHint)
            }
        }
        .frame(height: metrics.full, alignment: .top)
        .background { surface(reveal: reveal) }
        .clipShape(Self.shape)
        .shadow(color: Color.ttBackgroundBrand.opacity(0.16), radius: 18, y: -4)
        .offset(y: metrics.full - height)
        // High priority, so a drag that starts on a card or a button moves the panel instead
        // of pressing what is under the finger. Taps still reach them.
        .highPriorityGesture(drag, isEnabled: detent != .full)
        .onChange(of: detent) { _, new in
            if new != .full { scrollPosition.scrollTo(edge: .top) }
        }
        .preferredSensoryFeedback(.impact(weight: .light), trigger: detent)
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.ttTextSecondary.opacity(0.45))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .contentShape(.rect)
            .gesture(drag)
            .onTapGesture { settle(on: detent == .full ? .half : (detent == .half ? .full : .half)) }
            .accessibilityElement()
            .accessibilityIdentifier("journeyDrawerGrabber")
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: settle(on: JourneyDrawerDetent(rawValue: detent.rawValue + 1) ?? .full)
                case .decrement: settle(on: JourneyDrawerDetent(rawValue: detent.rawValue - 1) ?? .peek)
                @unknown default: break
                }
            }
    }

    private var accessibilityValue: String {
        switch detent {
        case .peek: "Summary"
        case .half: "Half height"
        case .full: "Full height"
        }
    }

    /// Frosted over the map as a summary; the page wash once the journey is being read.
    @ViewBuilder
    private func surface(reveal: Double) -> some View {
        if reduceTransparency || contrast == .increased {
            Color.ttBackgroundSurface
        } else {
            ZStack {
                JourneyPanelSurface()
                JourneyAmbientBackground(mood: mood).opacity(reveal * 0.82)
            }
        }
    }

    private var currentHeight: CGFloat {
        let raw = metrics.height(for: detent) - dragOffset
        if raw > metrics.full { return metrics.full + (raw - metrics.full) * 0.15 }
        if raw < metrics.peek { return metrics.peek - (metrics.peek - raw) * 0.25 }
        return raw
    }

    /// 0 at the summary strip, 1 from half height up.
    private func revealProgress(height: CGFloat) -> Double {
        let span = max(metrics.half - metrics.peek, 1)
        return Double(min(max((height - metrics.peek) / span, 0), 1))
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                // A sideways slide that starts on the ticket's line looks along the route on the
                // map. Once it has started, it keeps the drag whichever way the finger wanders.
                if dragOffset == 0, let mapLink, detent == .half,
                   mapLink.isScrubbing || abs(value.translation.width) > abs(value.translation.height),
                   mapLink.scrub(start: value.startLocation, location: value.location) {
                    return
                }
                // A sideways drag belongs to whatever is under the finger.
                guard abs(value.translation.height) > abs(value.translation.width) * 0.8 || dragOffset != 0 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if let mapLink, mapLink.isScrubbing {
                    mapLink.endScrub()
                    return
                }
                let projected = metrics.height(for: detent) - value.predictedEndTranslation.height
                let target = JourneyDrawerDetent.allCases.min {
                    abs(metrics.height(for: $0) - projected) < abs(metrics.height(for: $1) - projected)
                } ?? detent
                settle(on: target)
            }
    }

    private func settle(on target: JourneyDrawerDetent) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.86)) {
            detent = target
            dragOffset = 0
        }
    }
}
