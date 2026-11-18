import SwiftUI

/// The most recent booking uses the same engraved stock as a live ticket. Its marks are the
/// actual two endpoints, service and boarding date; they make no claim about live tracking.
struct JourneyHistoryInkTicket: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var engravingWidth: CGFloat = 100
    let ticket: JourneyHistoryTicket
    private let secondaryInk = Color.ttTextOnBrand.opacity(0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { proxy in
                    proxy.size.width >= 228 ? min(122, max(90, (proxy.size.width * 0.34).rounded())) : 0
                }) { engravingWidth = $0 }
                .padding(.horizontal, LayoutMetrics.cardInset)
                .padding(.top, LayoutMetrics.cardInset)
                .padding(.bottom, TrainTrackerSpacing.space6)
                .frame(maxWidth: .infinity, alignment: .leading)

            TicketPerforation.onInk

            HStack(spacing: TrainTrackerSpacing.space12) {
                Text(ticket.day)
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ttTextOnBrand)
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
                    Text(ticket.weekday)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(secondaryInk)
                    if let time = ticket.timeText {
                        Text(time)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.ttTextOnBrand)
                    }
                    if let status = ticket.disruption {
                        Text(status.text)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.ttTextOnBrand)
                    }
                }
                Spacer(minLength: 0)
                if engravingWidth == 0, !dynamicTypeSize.isAccessibilitySize, let trace = ticket.routeTrace {
                    JourneyHistoryRouteEngraving(trace: trace)
                        .frame(width: 70, height: 48)
                }
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(secondaryInk)
            }
            .padding(.horizontal, LayoutMetrics.cardInset)
            .padding(.top, TrainTrackerSpacing.space2)
            .padding(.bottom, LayoutMetrics.cardInset)
        }
        .fixedSize(horizontal: false, vertical: true)
        .liveTicketStyle()
    }

    @ViewBuilder
    private var header: some View {
        if let trace = ticket.routeTrace, engravingWidth > 0, !dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .center, spacing: TrainTrackerSpacing.space12) {
                routeNames
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                JourneyHistoryRouteEngraving(trace: trace)
                    .frame(width: engravingWidth, height: 102)
            }
        } else {
            routeNames
        }
    }

    private var routeNames: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            if !ticket.service.isEmpty {
                Text(ticket.service)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(secondaryInk)
            }
            VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                Text(ticket.origin)
                HStack(alignment: .firstTextBaseline, spacing: TrainTrackerSpacing.space6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.ttRouteOnInk)
                    Text(ticket.destination)
                }
            }
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color.ttTextOnBrand)
            if let scope = ticket.cityScope {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(secondaryInk)
            }
        }
    }
}

/// A fine twin rail and its transverse ties follow the station pattern. The dashed registration
/// lines intersect at the actual endpoint locations and the codes are printed only when known.
private struct JourneyHistoryRouteEngraving: View {
    let trace: JourneyHistoryRouteTrace

    var body: some View {
        Canvas { context, size in
            let field = CGRect(origin: .zero, size: size)
            let hasCodes = trace.originCode != nil || trace.destinationCode != nil
            let legs = trace.projected(in: field.insetBy(dx: hasCodes ? 16 : 8, dy: hasCodes ? 15 : 8))
            guard let start = legs.first?.first, let end = legs.last?.last else { return }
            var guides = Path()
            for stop in [start, end] {
                guides.move(to: CGPoint(x: 0, y: stop.y))
                guides.addLine(to: CGPoint(x: size.width, y: stop.y))
                guides.move(to: CGPoint(x: stop.x, y: 1))
                guides.addLine(to: CGPoint(x: stop.x, y: size.height - 1))
            }
            context.stroke(guides, with: .color(.ttTextOnBrand.opacity(0.32)),
                           style: StrokeStyle(lineWidth: 0.7, dash: [1, 4]))

            var rails = Path()
            var ties = Path()
            for leg in legs {
                guard let first = leg.first else { continue }
                rails.move(to: first)
                var remaining: CGFloat = 4
                for (a, b) in zip(leg, leg.dropFirst()) {
                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let length = hypot(dx, dy)
                    guard length > 0 else { continue }
                    rails.addLine(to: b)
                    let x = dx / length, y = dy / length
                    while remaining < length {
                        let centre = CGPoint(x: a.x + x * remaining, y: a.y + y * remaining)
                        ties.move(to: CGPoint(x: centre.x - 3.2 * y, y: centre.y + 3.2 * x))
                        ties.addLine(to: CGPoint(x: centre.x + 3.2 * y, y: centre.y - 3.2 * x))
                        remaining += 6
                    }
                    remaining -= length
                }
            }
            context.stroke(ties, with: .color(.ttTextOnBrand.opacity(0.85)), lineWidth: 1.1)
            context.stroke(rails, with: .color(.ttRouteOnInk), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.stroke(rails, with: .color(.ttBackgroundBrand), lineWidth: 1)

            // A small eyelet marks the end of a selected leg where the rider changed trains.
            for leg in legs.dropLast() {
                guard let via = leg.last, hypot(via.x - start.x, via.y - start.y) > 7,
                      hypot(via.x - end.x, via.y - end.y) > 7 else { continue }
                let eyelet = Path(ellipseIn: CGRect(x: via.x - 3.2, y: via.y - 3.2, width: 6.4, height: 6.4))
                context.fill(eyelet, with: .color(.ttBackgroundBrand))
                context.stroke(eyelet, with: .color(.ttTextOnBrand), lineWidth: 1.5)
            }
            for (point, filled) in [(start, false), (end, true)] {
                let circle = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                context.fill(circle, with: .color(filled ? .ttTextOnBrand : .ttBackgroundBrand))
                context.stroke(circle, with: .color(.ttTextOnBrand), lineWidth: 1.5)
            }

            let offset: CGFloat = start.y >= end.y ? 11 : -11
            for (point, code, dy) in [(start, trace.originCode, offset), (end, trace.destinationCode, -offset)] {
                if let code {
                    let label = Text(verbatim: code)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.ttTextOnBrand.opacity(0.9))
                    context.draw(label, at: CGPoint(x: point.x, y: point.y + dy))
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
