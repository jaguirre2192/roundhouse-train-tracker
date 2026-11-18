import SwiftUI
import TrainTrackerCore

extension JourneyTrust {
    init(card: ActiveTripCardPresentation) {
        self.init(
            freshness: TripFreshness(lastSuccessfulCheck: card.lastSuccessfulCheck, lastRefreshFailed: card.lastRefreshFailed),
            timingBasis: card.effectiveProgress.timingBasis,
            phase: card.effectiveProgress.phase,
            referenceDate: card.referenceDate
        )
    }

    /// Blue is live only; everything else stays quiet. Saved times never take an alarm color.
    var color: Color {
        switch self {
        case .live: .ttActionLive
        case .estimated, .timetable: .ttTextOperational
        case .saved: .ttTextSecondary
        }
    }

    var colorOnInk: Color {
        switch self {
        case .live: .ttActionLiveOnInk
        case .estimated, .timetable: .ttRouteOnInk
        case .saved: Color.ttTextOnBrand.opacity(0.72)
        }
    }
}

/// The one mark for how current a journey's times are. It reads the same on the rail chip, the
/// ticket, the map and the journey's summary strip.
struct JourneyTrustMark: View {
    enum Style {
        /// Symbol, word and when it was checked.
        case line
        /// Symbol and word in a capsule, for the map.
        case capsule
        /// Symbol and word alone, for a control that supplies its own surface.
        case word
        /// The symbol alone, for a chip.
        case glyph
    }

    let trust: JourneyTrust
    var freshness: TripFreshness = .notChecked
    var referenceDate: Date = .now
    var style: Style = .line
    var onInk = false
    /// A fixed foreground where the mark sits on a guaranteed contrasting control surface.
    var foreground: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .line:
            label(text: trust.line(freshness: freshness, at: referenceDate))
                .font(.caption.weight(.medium))
        case .capsule:
            label(text: trust.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, TrainTrackerSpacing.space12)
                .padding(.vertical, TrainTrackerSpacing.space6)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(tint.opacity(0.24), lineWidth: TrainTrackerStroke.subtle) }
        case .word:
            label(text: trust.title)
                .font(.caption.weight(.semibold))
        case .glyph:
            symbol
                .font(.caption2.weight(.bold))
                .accessibilityLabel(trust.title)
        }
    }

    private var tint: Color { foreground ?? (onInk ? trust.colorOnInk : trust.color) }

    private func label(text: String) -> some View {
        HStack(spacing: TrainTrackerSpacing.space6) {
            symbol
            Text(text)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: text)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trust.line(freshness: freshness, at: referenceDate))
    }

    private var symbol: some View {
        Image(systemName: trust.systemImage)
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: trust == .live && !reduceMotion)
            .accessibilityHidden(true)
    }
}
