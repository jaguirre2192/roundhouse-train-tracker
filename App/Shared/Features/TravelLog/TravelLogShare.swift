import SwiftUI
import TrainTrackerCore
import UIKit
import LinkPresentation

/// A finished journey as a picture to send: the ink ticket with the line that was ridden drawn
/// to its real shape, what the ride came to, and the arrival stamp. It is drawn from plain
/// shapes at a fixed size so it renders the same off screen as on.
struct TravelLogShareCard: View {
    let entry: TravelLogEntry

    /// Four by five, the portrait most places show without cropping.
    static let size = CGSize(width: 360, height: 450)

    private let ink = Color(red: 0.063, green: 0.227, blue: 0.290)
    private let inkDeep = Color(red: 0.043, green: 0.176, blue: 0.227)
    private let ivory = Color(red: 0.980, green: 0.965, blue: 0.925)
    private let teal = Color(red: 0.365, green: 0.698, blue: 0.769)
    private let page = Color(red: 0.969, green: 0.965, blue: 0.949)

    var body: some View {
        VStack(spacing: 0) {
            ticket
                .padding(.horizontal, 22)
                .padding(.top, 24)
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                RoundhouseWordmark(width: 104)
                Spacer()
                Text(entry.departureText(.dateTime.year()))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .opacity(0.6)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(page)
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.product.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.departureText(.dateTime.day().month(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(ivory.opacity(0.72))

                RiddenLine(points: entry.path)
                    .stroke(teal, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .overlay { RiddenLineEnds(points: entry.path, fill: inkDeep, stroke: ivory) }
                    .frame(height: 158)
                    .padding(.vertical, 2)

                HStack(alignment: .firstTextBaseline) {
                    place(entry.originLabel, name: entry.originName, alignment: .leading)
                    Spacer(minLength: 8)
                    place(entry.destinationLabel, name: entry.destinationName, alignment: .trailing)
                }
            }
            .padding(18)

            // The tear line between the journey and its stub.
            Line()
                .stroke(ivory.opacity(0.34), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 1)
                .padding(.horizontal, 14)

            HStack(alignment: .center, spacing: 0) {
                fact(TravelLogFormat.distance(entry.distanceMeters), label: "Distance")
                fact(TravelLogFormat.duration(entry.duration), label: "On board")
                Spacer(minLength: 6)
                if entry.isArrivalConfirmed {
                    ArrivalStamp(place: entry.destinationLabel, date: entry.arrival, color: teal, compact: true)
                } else {
                    TimetableEndMark(color: ivory.opacity(0.72))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [ink, inkDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: inkDeep.opacity(0.28), radius: 14, y: 8)
        }
    }

    private func place(_ label: String, name: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.system(size: label.count <= 4 ? 40 : 24, weight: .bold))
                .foregroundStyle(ivory)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if name != label {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(ivory.opacity(0.72))
                    .lineLimit(1)
            }
        }
    }

    private func fact(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(ivory.opacity(0.6))
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(ivory)
                .lineLimit(1)
        }
        .padding(.trailing, 20)
    }

}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// The line ridden, fitted into a box at its true proportions.
struct RiddenLine: Shape {
    let points: [TravelLogEntry.Point]

    func path(in rect: CGRect) -> Path {
        let fitted = Self.fit(points, in: rect)
        var path = Path()
        guard let first = fitted.first else { return path }
        path.move(to: first)
        fitted.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }

    /// Longitude is narrowed by the latitude's cosine so the shape is not stretched, then the
    /// whole line is scaled to fit and centered. Fewer than two points gives nothing to draw.
    static func fit(_ points: [TravelLogEntry.Point], in rect: CGRect) -> [CGPoint] {
        guard points.count > 1 else { return [] }
        let middle = (points.map(\.latitude).min()! + points.map(\.latitude).max()!) / 2
        let narrow = max(cos(middle * .pi / 180), 0.1)
        let flat = points.map { CGPoint(x: $0.longitude * narrow, y: -$0.latitude) }
        let minX = flat.map(\.x).min()!, maxX = flat.map(\.x).max()!
        let minY = flat.map(\.y).min()!, maxY = flat.map(\.y).max()!
        let inset = rect.insetBy(dx: 8, dy: 8)
        let scale = min(inset.width / max(maxX - minX, 1e-9), inset.height / max(maxY - minY, 1e-9))
        let width = (maxX - minX) * scale, height = (maxY - minY) * scale
        let originX = inset.midX - width / 2, originY = inset.midY - height / 2
        return flat.map { CGPoint(x: originX + ($0.x - minX) * scale, y: originY + ($0.y - minY) * scale) }
    }
}

/// The two ends of the ridden line: a filled dot where it began, an open ring where it ended.
private struct RiddenLineEnds: View {
    let points: [TravelLogEntry.Point]
    let fill: Color
    let stroke: Color

    var body: some View {
        GeometryReader { proxy in
            let fitted = RiddenLine.fit(points, in: CGRect(origin: .zero, size: proxy.size))
            if let first = fitted.first, let last = fitted.last {
                Circle().fill(stroke).frame(width: 9, height: 9).position(first)
                Circle().fill(fill).overlay { Circle().strokeBorder(stroke, lineWidth: 2.5) }
                    .frame(width: 12, height: 12).position(last)
            }
        }
    }
}

/// A rendered stub, ready for the share sheet.
struct TravelLogShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String

    @MainActor var activityItemSource: any UIActivityItemSource { TravelLogActivityItem(self) }

    @MainActor
    init?(entry: TravelLogEntry) {
        self.init(artwork: TravelLogShareCard(entry: entry), title: "\(entry.originName) to \(entry.destinationName) by train")
    }

    @MainActor
    init?(edition: AnnualRailPrint) {
        self.init(artwork: AnnualRailPrintArtwork(edition: edition), title: "\(String(edition.year)) by rail · Roundhouse")
    }

    @MainActor
    private init?<Artwork: View>(artwork: Artwork, title: String) {
        let renderer = ImageRenderer(content: artwork.environment(\.colorScheme, .light))
        renderer.scale = 3
        guard let image = renderer.uiImage else { return nil }
        self.image = image
        self.title = title
    }
}

struct TravelLogShareSheet: UIViewControllerRepresentable {
    let item: TravelLogShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item.activityItemSource], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The native share sheet previews the titled artwork and hands the actual image to each destination.
private final class TravelLogActivityItem: NSObject, UIActivityItemSource {
    private let item: TravelLogShareItem

    init(_ item: TravelLogShareItem) { self.item = item }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { item.image }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { item.image }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { item.title }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = item.title
        metadata.imageProvider = NSItemProvider(object: item.image)
        return metadata
    }
}

/// What a finished journey leaves in the panel: its stub, torn from the ticket above the first
/// time the journey is seen after arriving, with the way to share it and to the Travel Log.
struct ArrivalKeepsake: View {
    let entry: TravelLogEntry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var log = TravelLog.shared
    @State private var torn = false
    @State private var tears = 0
    @State private var shareItem: TravelLogShareItem?

    private static let seenKey = "arrivalStub.tornJourneyIDs"

    var body: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space12) {
            TravelLogStub(entry: entry)
                // Torn from the ticket above: it hangs by a corner, then drops into place.
                .rotationEffect(.degrees(torn || reduceMotion ? 0 : -4), anchor: .topLeading)
                .offset(y: torn || reduceMotion ? 0 : -34)
                .opacity(torn ? 1 : 0)

            HStack(spacing: TrainTrackerSpacing.space12) {
                Button("Share Stub", systemImage: "square.and.arrow.up") {
                    shareItem = TravelLogShareItem(entry: entry)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("shareArrivalStub")
                .accessibilityHint("Shares a picture of this journey’s ticket stub")

                TripsRouteLink(route: .travelLog, marksSelection: false) {
                    HStack(spacing: TrainTrackerSpacing.space4) {
                        Text(logSummary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ttActionTint)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("travelLogLink")
            }
            .opacity(torn ? 1 : 0)
        }
        .preferredSensoryFeedback(.impact(weight: .medium), trigger: tears)
        .sheet(item: $shareItem) { TravelLogShareSheet(item: $0) }
        .onAppear(perform: tear)
    }

    private var logSummary: String {
        let journeys = max(log.totals.journeys, 1)
        return journeys == 1 ? "Kept in Travel Log" : "Travel Log · \(journeys) journeys"
    }

    private func tear() {
        var seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        if seen.contains(entry.id) || LaunchFixtures.isActive && !ProcessInfo.processInfo.arguments.contains("-ArrivalStubPreview") {
            torn = true
            return
        }
        seen.append(entry.id)
        UserDefaults.standard.set(Array(seen.suffix(200)), forKey: Self.seenKey)
        // After the stamp has landed on the ticket above.
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.62).delay(1.0)) {
            torn = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.05))
            tears += 1
        }
    }
}
