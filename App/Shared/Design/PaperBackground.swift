import SwiftUI
import UIKit

/// The page as paper: a still, nearly flat sheet with a faint grain, a touch warm so it answers
/// the ivory printed on the ink tickets. Tickets rest on it like tickets on a desk. Nothing moves
/// and nothing changes with a trip's status; the tickets and the map carry that.
struct PaperBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color.ttBackgroundPaper
            .overlay {
                // The grain is one small tile, drawn once and repeated.
                if !reduceTransparency {
                    Image(uiImage: PaperGrain.tile)
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(0.5)
                }
            }
            .overlay {
                // The faintest fall of light down the sheet, so a tall page is not dead flat.
                LinearGradient(
                    colors: [Color.white.opacity(0.10), .clear, Color.ttBackgroundBrand.opacity(0.03)],
                    startPoint: .top, endPoint: .bottom
                )
            }
    }
}

/// A square of fine gray noise around middle gray, so overlaying it neither lightens nor darkens
/// the page on average. Seeded, so the grain is the same on every launch.
enum PaperGrain {
    static let tile: UIImage = {
        let side = 192
        var state: UInt64 = 0x7A11_C0DE_5EED
        var pixels = [UInt8](repeating: 128, count: side * side)
        for index in pixels.indices {
            // SplitMix64: small, fast and well spread.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            pixels[index] = UInt8(108 + Int(z % 41))
        }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )?.makeImage()
        }
        // Two noise cells to the point: fine enough to read as paper, not as static.
        return image.map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage()
    }()
}

/// What is printed, very faintly, on the white page so it reads as stock rather than as a blank
/// screen. Each takes its cue from something already on the tickets.
enum WhiteTexturePreference: String, CaseIterable, Identifiable {
    case none, grain, halftone, engraved, laid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .grain: "Grain"
        case .halftone: "Halftone"
        case .engraved: "Engraved"
        case .laid: "Laid"
        }
    }
}

/// The white page: pure white by day and inky gray by night, with an optional whisper of texture.
struct WhitePageBackground: View {
    @AppStorage(TrainTrackerPreference.whiteTexture) private var texture = WhiteTexturePreference.halftone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.ttBackgroundWhitePage
            .overlay {
                if !reduceTransparency { marks }
            }
    }

    /// Ink by day, ivory by night. Every texture stays under a few percent, so it is felt before
    /// it is seen and never competes with text.
    private var ink: Color { .ttTextBrand }
    private var strength: Double { colorScheme == .dark ? 0.75 : 0.65 }

    @ViewBuilder
    private var marks: some View {
        switch texture {
        case .none:
            EmptyView()
        case .grain:
            // The tooth of uncoated paper.
            Image(uiImage: PaperGrain.tile)
                .resizable(resizingMode: .tile)
                .blendMode(colorScheme == .dark ? .screen : .multiply)
                .opacity(colorScheme == .dark ? 0.10 : 0.085)
        case .halftone:
            // The ticket's halftone, let out across the page: dots that grow toward the lower
            // trailing corner and are gone where a screen's title is read.
            Canvas { context, size in
                let shading = GraphicsContext.Shading.color(ink.opacity(0.055 * strength))
                let pitch: CGFloat = 7
                var row = 0
                var y = pitch
                while y < size.height {
                    var x = pitch + (row.isMultiple(of: 2) ? 0 : pitch / 2)
                    while x < size.width {
                        let weight = pow((x / size.width) * 0.55 + (y / size.height) * 0.45, 2.2)
                        let radius = 1.9 * weight
                        if radius > 0.3 {
                            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: shading)
                        }
                        x += pitch
                    }
                    y += pitch * 0.866
                    row += 1
                }
            }
        case .engraved:
            // The guilloche from the ticket's stub: fine interleaved waves, as on security print.
            Canvas { context, size in
                let shading = GraphicsContext.Shading.color(ink.opacity(0.045 * strength))
                var wave = 0
                var waveY: CGFloat = 0
                while waveY < size.height + 8 {
                    let phase = CGFloat(wave) * 0.55
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: waveY))
                    var x: CGFloat = 0
                    while x <= size.width + 4 {
                        path.addLine(to: CGPoint(x: x, y: waveY + 3.2 * sin(x / 26 + phase) + 1.4 * sin(x / 9 - phase * 1.7)))
                        x += 4
                    }
                    context.stroke(path, with: shading, lineWidth: 0.6)
                    waveY += 7
                    wave += 1
                }
            }
        case .laid:
            // Laid paper: close fine lines across, with wider chain lines down.
            Canvas { context, size in
                let fine = GraphicsContext.Shading.color(ink.opacity(0.03 * strength))
                let chain = GraphicsContext.Shading.color(ink.opacity(0.035 * strength))
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: fine)
                    y += 3
                }
                var x: CGFloat = 24
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 0.75, height: size.height)), with: chain)
                    x += 32
                }
            }
        }
    }
}
