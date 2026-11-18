import SwiftUI

/// A readable panel over the map, honoring the rider's material accessibility settings.
struct JourneyPanelSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            Color.ttBackgroundSurface
        } else {
            // A frosted edge borrows the map's color; a stronger veil behind the reading
            // surface keeps small operational text legible on light and dark terrain.
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.ttBackgroundSurface.opacity(0.76))
        }
    }
}
