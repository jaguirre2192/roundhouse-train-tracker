import SwiftUI

/// The feeling of the page behind the focused journey. It follows the status the ticket shows
/// and the badge's truth rule: until this session's first successful check, "on time" and "late"
/// describe saved data, so the page stays calm rather than taking an alarm colour.
enum JourneyMood: String, Hashable {
    case calm
    case onTime
    case delayed
    case cancelled

    init(status: TripPresentationStatus.Kind, isConfirmed: Bool) {
        switch status {
        case .cancelled: self = .cancelled
        case .delayed where isConfirmed: self = .delayed
        case .onTime where isConfirmed: self = .onTime
        case .onTime, .delayed, .arrived, .scheduled, .estimated, .unavailable: self = .calm
        }
    }

    /// The wash never leaves the app's own teal and ink. Mood changes its depth, not its hue:
    /// route teal lifts it when things are well, ink weighs it down under disruption. Status
    /// colours stay on the words and symbols that name the status.
    fileprivate var accent: Color {
        switch self {
        case .calm, .onTime: .ttRouteActive
        case .delayed, .cancelled: .ttBackgroundBrand
        }
    }

    /// A hint of the status for glass controls; nothing while calm, so they keep the app tint.
    var glassTint: Color? {
        switch self {
        case .calm: nil
        case .onTime: .ttStatusOnTimeOnInk
        case .delayed: .ttStatusDelayedOnInk
        case .cancelled: .ttStatusCancelledOnInk
        }
    }

    /// How far the accent reaches into the page wash. Calm keeps the incumbent wash's quietness.
    fileprivate var strength: Double {
        switch self {
        case .calm: 0.55
        case .onTime: 0.9
        case .delayed: 0.5
        case .cancelled: 0.8
        }
    }
}

/// The page wash as a slow mesh gradient tinted by the journey's mood. It drifts continuously
/// and cross-fades when the mood changes. Reduce Motion and Low Power Mode hold it still, and
/// Increased Contrast replaces it with the plain canvas, as the static wash does.
struct JourneyAmbientBackground: View {
    let mood: JourneyMood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(TrainTrackerPreference.background) private var style = BackgroundPreference.standard
    @AppStorage(TrainTrackerPreference.statusTintsBackground) private var statusTints = true

    var body: some View {
        // Settings can stop a trip's status from colouring the page; the wash then stays calm.
        let mood = statusTints && style.takesStatusTint ? self.mood : .calm
        Group {
            if contrast == .increased {
                Color.ttBackgroundCanvas
            } else if style == .plain {
                Color.ttBackgroundSurface
            } else if style == .paper {
                PaperBackground()
            } else if style == .white {
                WhitePageBackground()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !drifts)) { context in
                    ZStack {
                        JourneyMoodMesh(mood: mood, time: drifts ? context.date.timeIntervalSinceReferenceDate : 0)
                            .id(mood)
                            .transition(.opacity)
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 1.6), value: mood)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var drifts: Bool {
        style == .moving && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

private struct JourneyMoodMesh: View {
    let mood: JourneyMood
    let time: TimeInterval

    var body: some View {
        let top = Color.ttBackgroundWashTop
        let bottom = Color.ttBackgroundWashBottom
        let strong = top.mix(with: mood.accent, by: 0.42 * mood.strength)
        let soft = top.mix(with: mood.accent, by: 0.18 * mood.strength)
        let middle = bottom.mix(with: mood.accent, by: 0.10 * mood.strength)

        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + wave(0.21, 0.16), 0], [1, 0],
                [0, 0.40 + wave(0.17, 0.08)], [0.5 + wave(0.13, 0.22), 0.34 + wave(0.19, 0.10, shift: 1.6)], [1, 0.44 + wave(0.15, 0.08, shift: 0.9)],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                strong, soft, top,
                soft, middle, strong,
                bottom, bottom, bottom,
            ]
        )
    }

    /// Trigonometry runs in Double: the reference-date interval is too large for Float precision.
    private func wave(_ speed: Double, _ amplitude: Double, shift: Double = 0) -> Float {
        Float(amplitude * sin(time * speed + shift))
    }
}
