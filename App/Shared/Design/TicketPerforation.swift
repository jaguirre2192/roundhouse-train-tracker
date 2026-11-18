import SwiftUI

/// The tear line between a Line Ticket's journey and its stub: a centred dashed rule. It reports
/// its position so `lineTicketStyle` can cut matching half-circle notches into the ticket's
/// edges, which then show whatever sits behind the ticket. Purely decorative.
struct TicketPerforation: View {
    static let height: CGFloat = 20

    var ruleColor: Color = .ttBorderSubtle

    var body: some View {
        Line()
            .stroke(ruleColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 5]))
            .frame(height: 1.5)
            .padding(.horizontal, TicketShape.notchRadius * 1.8)
            .frame(height: Self.height)
            .anchorPreference(key: TicketNotchAnchorKey.self, value: .center) { $0 }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

struct TicketNotchAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil

    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

/// A rounded ticket with two half-circle notches cut out of its side edges at `notchY`.
struct TicketShape: Shape {
    static let notchRadius: CGFloat = 10

    static let scallopRadius: CGFloat = 4

    var notchY: CGFloat?
    var cornerRadius: CGFloat = TrainTrackerRadius.card
    /// A torn-off stub: small half-circles cut along the bottom edge, as where a ticket parts
    /// from its book.
    var scallopedBottom = false

    func path(in rect: CGRect) -> Path {
        var cuts = Path()
        if let notchY, notchY > rect.minY + cornerRadius, notchY < rect.maxY - cornerRadius {
            let radius = Self.notchRadius
            cuts.addEllipse(in: CGRect(x: rect.minX - radius, y: notchY - radius, width: radius * 2, height: radius * 2))
            cuts.addEllipse(in: CGRect(x: rect.maxX - radius, y: notchY - radius, width: radius * 2, height: radius * 2))
        }
        if scallopedBottom {
            let radius = Self.scallopRadius
            let span = rect.width - cornerRadius * 2
            let count = max(Int(span / (radius * 3.4)), 1)
            let step = span / CGFloat(count)
            for index in 0..<count {
                let x = rect.minX + cornerRadius + step * (CGFloat(index) + 0.5)
                cuts.addEllipse(in: CGRect(x: x - radius, y: rect.maxY - radius, width: radius * 2, height: radius * 2))
            }
        }
        let body = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        return cuts.isEmpty ? body : body.subtracting(cuts)
    }
}

private struct LineTicketStyle: ViewModifier {
    let fill: Color
    let border: Color?
    /// Paper tickets on the page wash are frosted rather than white, like the rows beside them.
    var frostsOnWash = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(TrainTrackerPreference.background) private var page = BackgroundPreference.standard

    func body(content: Content) -> some View {
        let surface = frostsOnWash
            ? Color.ttSurfaceOnWash(solid: reduceTransparency || contrast == .increased, page: page)
            : AnyShapeStyle(fill)
        let elevation = TrainTrackerElevation.card

        content
            .backgroundPreferenceValue(TicketNotchAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    let shape = TicketShape(notchY: anchor.map { proxy[$0].y })
                    shape
                        .fill(surface)
                        .overlay {
                            if let border {
                                shape.stroke(border, lineWidth: TrainTrackerStroke.subtle)
                            }
                        }
                        .shadow(
                            color: Color.black.opacity(elevation.opacity),
                            radius: elevation.radius,
                            x: elevation.x,
                            y: elevation.y
                        )
                }
            }
    }
}

extension View {
    /// A Line Ticket surface with notches cut where its `TicketPerforation` sits, so the ticket
    /// works on any background. The optional border follows the notches.
    func lineTicketStyle(fill: Color = .ttBackgroundElevated, border: Color? = nil) -> some View {
        modifier(LineTicketStyle(fill: fill, border: border))
    }

    /// The live trip's ticket: ink paper in both appearances, engraved and lit like printed stock.
    func liveTicketStyle() -> some View {
        modifier(LiveTicketInkStyle())
    }

    /// Upcoming journeys and trains: white paper with a hairline that follows the notches.
    func ticketStubStyle() -> some View {
        modifier(LineTicketStyle(fill: .ttBackgroundElevated, border: .ttBorderSubtle, frostsOnWash: true))
    }
}

/// Ink ticket stock, printed like a paper ticket: light from the top leading corner, a halftone
/// grain across the journey, inked compartment rules, a guilloche on the stub and a scalloped
/// tear edge beneath it. The ticket lifts off the page on a soft ink shadow. Increased Contrast
/// and Reduce Transparency keep the plain ink and the plain edge.
private struct LiveTicketInkStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(TrainTrackerPreference.ticketTexture) private var printsTexture = true

    func body(content: Content) -> some View {
        let isPlain = contrast == .increased || reduceTransparency
        content
            .backgroundPreferenceValue(TicketNotchAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    let notchY = anchor.map { proxy[$0].y }
                    let shape = TicketShape(notchY: notchY, scallopedBottom: !isPlain)
                    shape
                        .fill(Color.ttBackgroundBrand)
                        .overlay {
                            // Settings can switch the printed grain off; the ticket keeps its shape.
                            if !isPlain && printsTexture {
                                TicketInkTexture(notchY: notchY).clipShape(shape)
                            }
                        }
                        .overlay {
                            if !isPlain {
                                shape.stroke(
                                    LinearGradient(
                                        colors: [Color.ttTextOnBrand.opacity(0.22), Color.ttTextOnBrand.opacity(0)],
                                        startPoint: .top, endPoint: .center
                                    ),
                                    lineWidth: 1
                                )
                            }
                        }
                        .compositingGroup()
                        .shadow(color: Color.ttBackgroundBrand.opacity(isPlain ? 0 : 0.30), radius: 16, x: 0, y: 12)
                        .shadow(color: Color.black.opacity(0.10), radius: 3, x: 0, y: 1)
                }
            }
    }
}

private struct TicketInkTexture: View {
    /// Where the perforation sits; the journey is above it, the stub below.
    let notchY: CGFloat?

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.09), location: 0),
                    .init(color: Color.white.opacity(0), location: 0.42),
                    .init(color: Color.black.opacity(0.16), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Canvas { context, size in
                let split = notchY ?? size.height
                let ink = GraphicsContext.Shading.color(Color.ttTextOnBrand.opacity(0.10))
                let fineInk = GraphicsContext.Shading.color(Color.ttTextOnBrand.opacity(0.07))
                let rule = GraphicsContext.Shading.color(Color.ttTextOnBrand.opacity(0.16))

                // Halftone grain over the journey: staggered dots that grow toward the trailing
                // edge and vanish where the service name and origin are read.
                let pitch: CGFloat = 6
                var row = 0
                var y = pitch
                while y < split - pitch {
                    var x = pitch + (row.isMultiple(of: 2) ? 0 : pitch / 2)
                    while x < size.width - pitch / 2 {
                        let weight = pow(x / size.width, 1.8)
                        let radius = 1.7 * weight
                        if radius > 0.25 {
                            context.fill(
                                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                with: ink
                            )
                        }
                        x += pitch
                    }
                    y += pitch * 0.866
                    row += 1
                }

                // Guilloche on the stub: two interleaved wave families, as on security print.
                var wave = 0
                var waveY = split + 4
                while waveY < size.height + 6 {
                    let phase = CGFloat(wave) * 0.55
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: waveY))
                    var x: CGFloat = 0
                    while x <= size.width + 3 {
                        path.addLine(to: CGPoint(x: x, y: waveY + 2.6 * sin(x / 20 + phase) + 1.3 * sin(x / 8 - phase * 1.7)))
                        x += 3
                    }
                    context.stroke(path, with: fineInk, lineWidth: 0.6)
                    waveY += 5
                    wave += 1
                }

                // Inked compartment rules: one frame for the journey, one for the stub.
                let inset: CGFloat = 7
                let corner = TrainTrackerRadius.card - inset
                let gap = TicketPerforation.height / 2
                if split > inset + gap + corner {
                    let journey = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: split - gap - inset)
                    context.stroke(Path(roundedRect: journey, cornerRadius: corner, style: .continuous), with: rule, lineWidth: 0.75)
                }
                let stubHeight = size.height - split - gap - inset - TicketShape.scallopRadius
                if notchY != nil, stubHeight > corner {
                    let stub = CGRect(x: inset, y: split + gap, width: size.width - inset * 2, height: stubHeight)
                    context.stroke(Path(roundedRect: stub, cornerRadius: corner, style: .continuous), with: rule, lineWidth: 0.75)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Abstract code bars for a ticket stub, as on the app icon. They are drawn from a hash of the
/// seed so one train keeps one pattern, and they never encode a station or a real barcode.
struct TicketCodeBars: View {
    let seed: String
    var color: Color = Color.ttTextOnBrand.opacity(0.5)

    var body: some View {
        Canvas { context, size in
            var state = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
            func next() -> CGFloat {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(1 + (state >> 33) % 3)
            }
            var x: CGFloat = 0
            while true {
                let width = next()
                let gap = next()
                if x + width > size.width { break }
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(color))
                x += width + gap
            }
        }
        .frame(width: 64, height: 16)
        .accessibilityHidden(true)
    }
}

extension TicketPerforation {
    /// The tear line as drawn on the ink live ticket.
    static var onInk: TicketPerforation {
        TicketPerforation(ruleColor: Color.ttTextOnBrand.opacity(0.24))
    }
}

#Preview("Ticket Perforation") {
    VStack(spacing: 0) {
        Text("NYP → WAS")
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 120)
        TicketPerforation()
        Text("Track 2")
            .frame(maxWidth: .infinity, minHeight: 60)
    }
    .lineTicketStyle(border: .ttBorderSubtle)
    .padding(LayoutMetrics.pageInset)
    .background(Color.ttBackgroundCanvas)
}
