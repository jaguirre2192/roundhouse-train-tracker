import SwiftUI

/// The approved lettering, tinted by its surface rather than carrying a second color palette.
struct RoundhouseWordmark: View {
    var width: CGFloat = 128

    var body: some View {
        Image("RoundhouseWordmark")
            .renderingMode(.template)
            .resizable()
            .scaledToFill()
            // Crop only the generated asset's transparent vertical clear space. The complete
            // lettering sits inside this ratio, including the capital R's split-rail detail.
            .frame(width: width, height: width / 6.4)
            .clipped()
            .accessibilityLabel("Roundhouse")
    }
}
