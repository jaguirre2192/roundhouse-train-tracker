import MapKit
import SwiftUI

/// Personal display preferences, stored on this device. Each one changes how Train Tracker looks
/// or feels; none changes what the data says, so truthful live, estimated and saved states are
/// the same whatever is chosen here. Accessibility settings always win over a preference.
enum TrainTrackerPreference {
    static let appearance = "preference.appearance"
    static let background = "preference.background"
    static let statusTintsBackground = "preference.statusTintsBackground"
    static let ticketTexture = "preference.ticketTexture"
    static let liveHaptics = "preference.liveHaptics"
    static let mapStyle = "preference.mapStyle"
    /// What is printed faintly on the White page.
    static let whiteTexture = "preference.whiteTexture"
    /// Start the Lock Screen Live Activity by itself once a train is within its window.
    static let autoLockScreen = "preference.autoLockScreen"

    static let all = [
        appearance, background, statusTintsBackground, ticketTexture, liveHaptics, mapStyle, autoLockScreen, whiteTexture,
    ]

    /// Puts every preference back to how the app ships.
    static func resetAll(in defaults: UserDefaults = .standard) {
        all.forEach(defaults.removeObject(forKey:))
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The page wash behind ticket screens.
enum BackgroundPreference: String, CaseIterable, Identifiable {
    // In the order Settings offers them: the page the app ships with first.
    case white, paper, moving, still, plain

    /// The page the app ships with: white, with the halftone texture (Jorge, November 13, 2026).
    static let standard = BackgroundPreference.white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moving: "Moving"
        case .still: "Still"
        case .plain: "Plain"
        case .paper: "Paper"
        case .white: "White"
        }
    }

    var detail: String {
        switch self {
        case .moving: "Color drifts slowly behind your trips."
        case .still: "The same color, without motion."
        case .plain: "A flat page with no color wash."
        case .paper: "A still, warm sheet with a faint grain, like ticket stock."
        case .white: "A clean white page, with groups on light gray."
        }
    }

    /// A page that is one flat color, where a group is a sheet of its own color instead of frost.
    var isFlatSheet: Bool { self == .paper || self == .white }

    /// Whether a trip's status can tint the page. A flat page, paper and white never change color.
    var takesStatusTint: Bool { self == .moving || self == .still }
}

enum MapStylePreference: String, CaseIterable, Identifiable {
    case muted, detailed, satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .muted: "Quiet"
        case .detailed: "Detailed"
        case .satellite: "Satellite"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .muted: .standard(elevation: .flat, emphasis: .muted)
        case .detailed: .standard(elevation: .flat, emphasis: .automatic)
        case .satellite: .hybrid(elevation: .flat)
        }
    }

    /// Satellite imagery is dark and busy, so route lines take fixed ivory casings there.
    var usesImagery: Bool { self == .satellite }
}

/// Haptics that mark a live change or a selection, silenced when the rider turns them off.
private struct PreferredSensoryFeedback<Trigger: Equatable>: ViewModifier {
    @AppStorage(TrainTrackerPreference.liveHaptics) private var liveHaptics = true
    let feedback: SensoryFeedback
    let trigger: Trigger

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { _, _ in liveHaptics ? feedback : nil }
    }
}

extension View {
    /// `sensoryFeedback` that respects the Haptics preference in Settings.
    func preferredSensoryFeedback(_ feedback: SensoryFeedback, trigger: some Equatable) -> some View {
        modifier(PreferredSensoryFeedback(feedback: feedback, trigger: trigger))
    }
}
