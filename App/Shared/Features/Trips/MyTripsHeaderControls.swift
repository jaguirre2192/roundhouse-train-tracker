import SwiftUI

extension View {
    /// Related header controls share a rendering context without adding a glass shelf.
    func myTripsHeaderGlassContainer() -> some View {
        modifier(MyTripsHeaderGlassContainer())
    }

    func myTripsCircleButton(tint: Color?) -> some View {
        modifier(MyTripsCircleButtonStyle(tint: tint))
    }
}

extension EnvironmentValues {
    /// Each control floats independently over the map, at the same height as its rail pills.
    @Entry var myTripsHeaderFloats = false
}

private struct MyTripsHeaderGlassContainer: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
            // Keep the established gaps: independent discs must not merge at rest.
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

/// The map disc and the native list button share one accessibility fallback.
struct MyTripsCircleButtonStyle: ViewModifier {
    let tint: Color?
    @Environment(\.myTripsHeaderFloats) private var floats
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// The height of a rail pill, so discs and pills line up.
    static let floatingSide: CGFloat = 52

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.buttonStyle(SolidCircle(increasedContrast: contrast == .increased))
        } else if floats {
            content
                .buttonStyle(.plain)
                .foregroundStyle(Color.ttActionTint)
                .frame(width: Self.floatingSide, height: Self.floatingSide)
                .modifier(FloatingGlass(tint: tint))
                .contentShape(Circle())
        } else if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass(tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular))
                .buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }

    /// Opaque in both appearances, with a native Button's semantics and a visible press state.
    private struct SolidCircle: ButtonStyle {
        let increasedContrast: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(Color.ttActionTint)
                .frame(width: MyTripsCircleButtonStyle.floatingSide, height: MyTripsCircleButtonStyle.floatingSide)
                .background(
                    configuration.isPressed ? Color.ttBackgroundBrandSubtle : .ttBackgroundElevated,
                    in: Circle()
                )
                .overlay {
                    Circle().strokeBorder(increasedContrast ? Color.ttTextSecondary : .ttBorderSubtle)
                }
                .contentShape(Circle())
        }
    }

    private struct FloatingGlass: ViewModifier {
        let tint: Color?

        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(
                    tint.map { Glass.regular.tint($0.opacity(0.22)).interactive() } ?? .regular.interactive(),
                    in: Circle()
                )
            } else {
                content
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: Color.ttBackgroundBrand.opacity(0.14), radius: 8, y: 3)
            }
        }
    }
}
