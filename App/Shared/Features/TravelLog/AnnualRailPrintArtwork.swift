import SwiftUI

/// Fixed-size paper original. The on-screen proof and the exported image use this same view.
struct AnnualRailPrintArtwork: View {
    static let size = CGSize(width: 360, height: 480)
    let edition: AnnualRailPrint

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                RoundhouseWordmark(width: 112)
                Spacer()
                issueMark
            }
            .frame(height: 32)

            Rectangle().fill(Color.ttBackgroundBrand).frame(height: 1)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 0) {
                Text("My year by rail")
                    .font(.system(size: 19, weight: .medium, design: .serif).italic())
                HStack(alignment: .lastTextBaseline) {
                    Text(verbatim: String(edition.year))
                        .font(.system(size: 65, weight: .heavy))
                        .monospacedDigit()
                        .tracking(-3)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(edition.rideCountLabel)
                            .font(.system(size: 16, weight: .bold))
                        if let distance = edition.distanceLabel {
                            Text(distance)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                }
            }
            .padding(.top, 13)

            AnnualRailPrintAtlas(edition: edition)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 13)

            if let latest = edition.entries.last {
                let featured = edition.longest
                Text(featured == nil ? "Latest ride" : edition.longestLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.2)
                Text("\(featured?.originName ?? latest.originName) → \(featured?.destinationName ?? latest.destinationName)")
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(featured?.serviceLabel ?? latest.product)
                    if let featured {
                        Text("·")
                        Text("About \(TravelLogFormat.distance(featured.distanceMeters))")
                            .fixedSize()
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 4)
            }
        }
        .padding(22)
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(Color.ttBackgroundBrand)
        .background(Color.ttBackgroundPaper)
        .environment(\.colorScheme, .light)
    }

    private var issueMark: some View {
        VStack(spacing: 2) {
            Text("PRINTED").font(.system(size: 7.5, weight: .semibold)).tracking(1.6)
            Text(edition.issued.formatted(.dateTime.day().month(.abbreviated).year()).uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.ttBackgroundBrand.opacity(0.7), lineWidth: 0.8) }
    }
}

private struct AnnualRailPrintAtlas: View {
    let edition: AnnualRailPrint

    var body: some View {
        Group {
            if edition.plates.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Journey register").font(.system(size: 16, weight: .semibold, design: .serif))
                    ForEach(edition.entries.prefix(3)) { entry in
                        Text("\(entry.originName) → \(entry.destinationName)").font(.system(size: 12, weight: .medium))
                    }
                    Text("Route lines unavailable").font(.system(size: 10))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(16)
            } else {
                HStack(spacing: 1) {
                    if let first = edition.plates.first {
                        panel(first, large: true)
                    }
                    if edition.plates.count > 1 {
                        VStack(spacing: 1) {
                            ForEach(edition.plates.indices.dropFirst(), id: \.self) { index in
                                panel(edition.plates[index], large: false)
                            }
                        }
                        .frame(maxWidth: edition.plates.count == 3 ? 114 : .infinity)
                    }
                }
            }
        }
        .foregroundStyle(Color.ttTextOnBrand)
        .background(Color.ttBackgroundBrand)
        .clipped()
    }

    private func panel(_ plate: AnnualRailPlate, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                // Survey crosses keep north and scale legible between disconnected route insets.
                var marks = Path()
                for x in stride(from: CGFloat(6), through: size.width, by: 24) {
                    for y in stride(from: CGFloat(6), through: size.height, by: 24) {
                        marks.move(to: CGPoint(x: x - 1.5, y: y))
                        marks.addLine(to: CGPoint(x: x + 1.5, y: y))
                        marks.move(to: CGPoint(x: x, y: y - 1.5))
                        marks.addLine(to: CGPoint(x: x, y: y + 1.5))
                    }
                }
                context.stroke(marks, with: .color(.ttTextOnBrand.opacity(0.18)), lineWidth: 0.7)
                let insets = large ? CGFloat(12) : 5
                let lines = plate.projected(in: CGRect(origin: .zero, size: size).insetBy(dx: insets, dy: insets))
                for line in lines {
                    guard let first = line.first, let last = line.last else { continue }
                    var path = Path()
                    path.addLines(line)
                    context.stroke(path, with: .color(.ttRouteOnInk),
                                   style: StrokeStyle(lineWidth: large ? 3.4 : 2.5, lineCap: .round, lineJoin: .round))
                    let r: CGFloat = large ? 3.7 : 2.6
                    context.fill(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.ttTextOnBrand))
                    let end = Path(ellipseIn: CGRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2))
                    context.fill(end, with: .color(.ttBackgroundBrand))
                    context.stroke(end, with: .color(.ttTextOnBrand), lineWidth: large ? 2 : 1.4)
                }
            }
            Text(plate.caption)
                .font(.system(size: large ? 10 : 8.5, weight: .bold, design: .monospaced))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(large ? 12 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay { Rectangle().strokeBorder(Color.ttTextOnBrand.opacity(0.2), lineWidth: 0.7) }
    }
}
