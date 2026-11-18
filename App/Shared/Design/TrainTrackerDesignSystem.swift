import SwiftUI
import UIKit

enum TrainTrackerSpacing {
    static let space0: CGFloat = 0
    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space6: CGFloat = 6
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space18: CGFloat = 18
    static let space20: CGFloat = 20
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space48: CGFloat = 48
    static let space84: CGFloat = 84
}

enum TrainTrackerRadius {
    static let icon: CGFloat = 9
    static let status: CGFloat = 14
    static let control: CGFloat = 16
    static let group: CGFloat = 18
    static let card: CGFloat = 20
    static let hero: CGFloat = 22
    static let full: CGFloat = 999
}

enum TrainTrackerStroke {
    static let subtle: CGFloat = 0.75
}

struct TrainTrackerShadow: Sendable {
    let opacity: Double
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum TrainTrackerElevation {
    static let card = TrainTrackerShadow(opacity: 0.035, radius: 14, x: 0, y: 7)
    static let overlay = TrainTrackerShadow(opacity: 0.12, radius: 10, x: 0, y: 4)
    static let mapOverlay = TrainTrackerShadow(opacity: 0.07, radius: 8, x: 0, y: 3)
}

private struct TrainTrackerSurfaceModifier: ViewModifier {
    /// Nil is the frosted surface every page uses on the wash; a color is a deliberate state.
    let color: Color?
    let radius: CGFloat
    let elevation: TrainTrackerShadow?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(TrainTrackerPreference.background) private var page = BackgroundPreference.standard

    func body(content: Content) -> some View {
        content
            .background(
                color.map { AnyShapeStyle($0) }
                    ?? Color.ttSurfaceOnWash(solid: reduceTransparency || contrast == .increased, page: page),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(color == nil ? Color.ttSurfaceRule(page: page) : Color.ttBorderSubtle, lineWidth: TrainTrackerStroke.subtle)
            }
            .shadow(
                color: Color.black.opacity(elevation?.opacity ?? 0),
                radius: elevation?.radius ?? 0,
                x: elevation?.x ?? 0,
                y: elevation?.y ?? 0
            )
    }
}

private struct TrainTrackerPageBackgroundModifier: ViewModifier {
    var mood: JourneyMood = .calm

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            // The wash drifts slowly and takes the mood of the journey a screen is about.
            // `JourneyAmbientBackground` owns the Increased Contrast, Reduce Motion and Low
            // Power fallbacks.
            .background { JourneyAmbientBackground(mood: mood) }
    }
}

private struct TrainTrackerRowSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(TrainTrackerPreference.background) private var page = BackgroundPreference.standard

    func body(content: Content) -> some View {
        content.listRowBackground(Rectangle().fill(
            Color.ttSurfaceOnWash(solid: reduceTransparency || contrast == .increased, page: page)
        ))
    }
}

extension Color {
    /// The surface for rows and paper cards that sit on the page wash.
    /// On a flat page it is a sheet of its own color, since frost has nothing to frost there:
    /// a lighter sheet on paper, light gray on white.
    static func ttSurfaceOnWash(solid: Bool, page: BackgroundPreference = .standard) -> AnyShapeStyle {
        if solid { return AnyShapeStyle(Color.ttBackgroundElevated) }
        switch page {
        case .paper: return AnyShapeStyle(Color.ttBackgroundPaperSheet)
        case .white: return AnyShapeStyle(Color.ttBackgroundGroupOnWhite)
        case .moving, .still, .plain: return AnyShapeStyle(.thinMaterial)
        }
    }

    /// The edge of a group on the page: a fine ink rule on paper, nothing on white (the gray
    /// fill is its edge), a hairline elsewhere.
    static func ttSurfaceRule(page: BackgroundPreference) -> Color {
        switch page {
        case .paper: .ttRuleOnPaper
        case .white: .clear
        case .moving, .still, .plain: .ttBorderSubtle
        }
    }
}

/// Lists share the ticket screens' page wash; their rows are frosted surfaces on it.
private struct TrainTrackerListCanvasModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(TrainTrackerPageBackgroundModifier())
    }
}

extension View {
    /// A grouped surface. By default it is frosted, so it takes the page's color instead of
    /// sitting on it as a white box; pass a color only for a state, such as selected.
    func trainTrackerSurface(
        color: Color? = nil,
        radius: CGFloat = TrainTrackerRadius.group,
        elevation: TrainTrackerShadow? = nil
    ) -> some View {
        modifier(TrainTrackerSurfaceModifier(color: color, radius: radius, elevation: elevation))
    }

    /// The softly blended, slowly moving page background used behind ticket screens. A screen
    /// about one journey passes that journey's mood; everything else stays calm.
    func trainTrackerPageBackground(mood: JourneyMood = .calm) -> some View {
        modifier(TrainTrackerPageBackgroundModifier(mood: mood))
    }

    func trainTrackerListCanvas() -> some View {
        modifier(TrainTrackerListCanvasModifier())
    }

    /// A grouped row on the page wash: frosted, so it takes the wash's colour instead of sitting
    /// on it as a white box. Reduce Transparency and Increased Contrast keep the solid surface.
    func trainTrackerRowSurface() -> some View {
        modifier(TrainTrackerRowSurfaceModifier())
    }

    func trainTrackerPrimaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color.ttBackgroundBrand)
    }
}

extension Color {
    /// Neutral blue-gray ink in Dark Mode, with a small tonal lift for each surface above it.
    static let ttBackgroundCanvas = trainTrackerDynamic(light: 0xFFFFFF, dark: 0x1C2429)
    static let ttBackgroundSurface = trainTrackerDynamic(light: 0xF6F7F5, dark: 0x232D32)
    static let ttBackgroundElevated = trainTrackerDynamic(light: 0xFFFFFF, dark: 0x2B363C)
    /// The paper page: warm near-white by day, deep ink by night.
    static let ttBackgroundPaper = trainTrackerDynamic(light: 0xF5F2EA, dark: 0x0D181C)
    /// A sheet resting on the paper page, a step lighter than it.
    static let ttBackgroundPaperSheet = trainTrackerDynamic(light: 0xFDFBF6, dark: 0x16242A)
    /// The white page: pure white by day, the same inky gray as the canvas by night.
    static let ttBackgroundWhitePage = ttBackgroundCanvas
    /// A group on the white page: light neutral gray by day, lifted ink by night, with no border.
    static let ttBackgroundGroupOnWhite = trainTrackerDynamic(light: 0xF2F3F5, dark: 0x273137)
    /// The fine rule around a sheet on paper.
    static let ttRuleOnPaper = trainTrackerDynamic(light: 0xDED9CC, dark: 0x2B3D44)
    static let ttBackgroundBrand = trainTrackerDynamic(light: 0x123D4B, dark: 0x123D4B)
    static let ttBackgroundBrandSubtle = trainTrackerDynamic(light: 0xE6F1F3, dark: 0x33454B)

    static let ttTextPrimary = trainTrackerDynamic(light: 0x162025, dark: 0xFFFFFF)
    static let ttTextSecondary = trainTrackerDynamic(light: 0x667276, dark: 0xB7C1C4)
    /// Ink on light surfaces, ivory in Dark Mode: brand-coloured text such as ticket station codes.
    static let ttTextBrand = trainTrackerDynamic(light: 0x123D4B, dark: 0xFFF8E8)
    static let ttTextOnBrand = trainTrackerDynamic(light: 0xFFF8E8, dark: 0xFFF8E8)
    static let ttTextOnStatus = trainTrackerDynamic(light: 0xFFF8E8, dark: 0x0B1519)
    /// Small operational rail text (badges, trackability, result counts, readiness state).
    /// Darker than `ttRouteActive` so caption-scale text clears 4.5:1 on every Train Tracker
    /// surface, including the brand-subtle recommended result card.
    static let ttTextOperational = trainTrackerDynamic(light: 0x2F6B78, dark: 0x74BCCA)

    static let ttBorderSubtle = trainTrackerDynamic(light: 0xEEF1EF, dark: 0x33454B)
    static let ttActionLive = trainTrackerDynamic(light: 0x007AFF, dark: 0x0A84FF)
    /// The app tint for buttons, links, toolbar items and the selected tab. Brand teal at text
    /// contrast (6.0:1 on white), so live blue stays reserved for current position and fresh data.
    static let ttActionTint = trainTrackerDynamic(light: 0x2F6B78, dark: 0x74BCCA)
    static let ttRouteActive = trainTrackerDynamic(light: 0x4C95A3, dark: 0x5DA5B2)
    /// Route teal and live blue as they sit on the ink live ticket, in both appearances. The
    /// Dark values keep route and live indicators at or above 3:1 against ink.
    static let ttRouteOnInk = trainTrackerDynamic(light: 0x5DA5B2, dark: 0x5DA5B2)
    static let ttActionLiveOnInk = trainTrackerDynamic(light: 0x0A84FF, dark: 0x0A84FF)
    /// Status colours as they sit on the ink live ticket, in both appearances.
    static let ttStatusOnTimeOnInk = trainTrackerDynamic(light: 0x30D158, dark: 0x30D158)
    static let ttStatusDelayedOnInk = trainTrackerDynamic(light: 0xFF9F0A, dark: 0xFF9F0A)
    static let ttStatusCancelledOnInk = trainTrackerDynamic(light: 0xFF453A, dark: 0xFF453A)
    /// The page wash: cool route-teal mist at the top blending into the canvas.
    static let ttBackgroundWashTop = trainTrackerDynamic(light: 0xD9E8EC, dark: 0x16323B)
    /// Where the wash settles: a faint cool mist, so white cards stay visible to the bottom.
    static let ttBackgroundWashBottom = trainTrackerDynamic(light: 0xF0F5F6, dark: 0x1C2429)
    static let ttRoutePassed = trainTrackerDynamic(light: 0xC7CECC, dark: 0x33454B)
    static let ttStatusOnTime = trainTrackerDynamic(light: 0x1F7A35, dark: 0x30D158)
    static let ttStatusDelayed = trainTrackerDynamic(light: 0xAD4F00, dark: 0xFF9F0A)
    /// Delay status on the ink brand surface; the Light status orange is too dark on ink.
    static let ttStatusDelayedOnBrand = trainTrackerDynamic(light: 0xFF9F0A, dark: 0xFF9F0A)
    /// Cancellation text on app surfaces clears 4.5:1, including brand-subtle. The ink ticket
    /// keeps its dedicated, more saturated `ttStatusCancelledOnInk` indicator.
    static let ttStatusCancelled = trainTrackerDynamic(light: 0xD70015, dark: 0xFF8F87)
    static let ttFocusRing = trainTrackerDynamic(light: 0x007AFF, dark: 0x0A84FF)

    private static func trainTrackerDynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: .trainTrackerDynamic(light: light, dark: dark))
    }
}

private extension UIColor {
    static func trainTrackerDynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            trainTrackerHex(traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    static func trainTrackerHex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
