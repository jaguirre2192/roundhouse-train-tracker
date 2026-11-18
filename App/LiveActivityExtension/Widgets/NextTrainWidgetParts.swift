import SwiftUI
import TrainTrackerCore
import WidgetKit

/// The Home Screen widget's colors. In full color the tile is the app's own page, white by day
/// and black by night, with ink text and the brand's teal. When the system tints or clears the
/// widget, or renders it vibrantly, hierarchical system styles take over so meaning rests on
/// text, not hue.
struct NextTrainInk {
    let isFullColor: Bool

    init(_ mode: WidgetRenderingMode) {
        isFullColor = mode == .fullColor
    }

    var primary: Color { isFullColor ? NextTrainPage.primary : .primary }
    var secondary: Color { isFullColor ? NextTrainPage.secondary : .secondary }
    var route: Color { isFullColor ? NextTrainPage.route : .primary }
    var rail: Color { isFullColor ? NextTrainPage.primary.opacity(0.16) : .secondary.opacity(0.5) }
    /// Live blue means a fresh realtime check only (brand guide 1.2).
    var live: Color { isFullColor ? NextTrainPage.live : .primary }

    func status(_ status: WidgetTrainPresentation.Status) -> Color {
        guard isFullColor else { return .primary }
        switch status {
        case .onTime: return NextTrainPage.onTime
        case .delayed: return NextTrainPage.delayed
        case .cancelled: return NextTrainPage.cancelled
        case .arrived: return NextTrainPage.route
        case .scheduled: return secondary
        }
    }
}

/// The page the widget is printed on and the colors that read on it, by day and by night.
enum NextTrainPage {
    static let background = dynamic(0xFFFFFF, 0x000000)
    static let primary = dynamic(0x162025, 0xFFFFFF)
    static let secondary = dynamic(0x667276, 0xA6B0B3)
    static let route = dynamic(0x2F6B78, 0x74BCCA)
    static let live = dynamic(0x007AFF, 0x0A84FF)
    static let onTime = dynamic(0x1F7A35, 0x30D158)
    static let delayed = dynamic(0xAD4F00, 0xFF9F0A)
    static let cancelled = dynamic(0xD70015, 0xFF453A)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1
            )
        })
    }
}

/// The widget's page. Marked as the container background, so the system replaces it with its
/// own glass in the Clear and Tinted Home Screen appearances.
struct NextTrainTicketBackground: View {
    var body: some View {
        NextTrainPage.background
    }
}

/// How current the widget's times are, in the app's own words: "Live · Checked 2 min ago",
/// "Saved · Not checked yet". A widget that shows a time also says how far to trust it.
struct NextTrainTrustLine: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let presentation: WidgetTrainPresentation
    /// Shown instead for the gallery sample or once the journey is over.
    var override: String? = nil

    var body: some View {
        let ink = NextTrainInk(renderingMode)
        let trust = presentation.trust
        HStack(spacing: 4) {
            if override == nil, trust == .live {
                Circle().fill(ink.live).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(override ?? "\(trust.title) · \(checked)")
        }
        .font(.caption2)
        .foregroundStyle(ink.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// When it was checked, without the word the trust word already implies: "3 min ago",
    /// "just now", "7:04 PM". A widget has no room to say "checked" twice.
    private var checked: String {
        let text = presentation.freshnessText()
        for prefix in ["Last checked ", "Checked "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}

/// Status written out beside a dot, as on the ticket's badge. A 5+ minute delay strikes the
/// timetable time through beside the estimate.
struct NextTrainStatusLine: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let presentation: WidgetTrainPresentation
    var font: Font = .caption.weight(.semibold)
    var showsStruckTime = true

    var body: some View {
        let ink = NextTrainInk(renderingMode)
        let color = ink.status(presentation.status)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(presentation.statusText)
                .foregroundStyle(color)
                .monospacedDigit()
            if showsStruckTime, let struck = presentation.struckTimetableCompactText {
                Text(struck)
                    .strikethrough(true, color: ink.secondary)
                    .foregroundStyle(ink.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("timetable \(struck)")
            }
        }
        .font(font)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var symbol: String {
        switch presentation.status {
        case .cancelled: "xmark.circle.fill"
        case .delayed: "clock.fill"
        case .arrived: "checkmark.circle.fill"
        case .onTime: "circle.fill"
        case .scheduled: "calendar"
        }
    }
}

/// Station codes joined by a route rail. Underway, the passed part is route teal and a marker
/// sits at the train's timetable position: live blue only for a fresh realtime check.
struct NextTrainRouteRail: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let presentation: WidgetTrainPresentation
    var codeFont: Font = .title3.weight(.bold)

    /// Small widgets stack station names when there are no codes instead of truncating them.
    var stacksNames = false

    var body: some View {
        if stacksNames, !presentation.hasCodes {
            names
        } else {
            codes
        }
    }

    private var names: some View {
        let ink = NextTrainInk(renderingMode)
        return VStack(alignment: .leading, spacing: 0) {
            Text(presentation.originLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink.primary)
            Text("→ \(presentation.destinationLabel)")
                .font(.caption)
                .foregroundStyle(ink.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .widgetAccentable()
        .accessibilityElement(children: .combine)
    }

    private var codes: some View {
        let ink = NextTrainInk(renderingMode)
        return HStack(spacing: 8) {
            Text(presentation.originLabel)
                .layoutPriority(1)
            rail(ink)
                .frame(minWidth: 16)
                .accessibilityHidden(true)
            Text(presentation.destinationLabel)
                .layoutPriority(1)
        }
        .font(presentation.hasCodes ? codeFont : .subheadline.weight(.semibold))
        .foregroundStyle(ink.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.train.boarding?.name ?? "") to \(presentation.train.alighting?.name ?? "")")
    }

    private func rail(_ ink: NextTrainInk) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let y = proxy.size.height / 2
            let progress = progressFraction
            ZStack(alignment: .leading) {
                Capsule().fill(ink.rail).frame(width: width, height: 2)
                Capsule().fill(ink.route).frame(width: max(0, width * progress), height: 2)
                Circle().fill(ink.route).frame(width: 7, height: 7)
                Circle().stroke(ink.primary, lineWidth: 1.5).frame(width: 7, height: 7)
                    .offset(x: width - 7)
                // The marker needs room to read apart from the end dots.
                if case .underway = presentation.phase, width >= 40 {
                    Circle()
                        .fill(isLive ? ink.live : ink.primary)
                        .overlay { Circle().stroke(NextTrainPage.background, lineWidth: ink.isFullColor ? 2 : 0) }
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(10, width * progress - 5), width - 20))
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .position(x: width / 2, y: y)
        }
        .frame(height: 10)
    }

    private var progressFraction: Double {
        switch presentation.phase {
        case .underway: presentation.legProgress
        case .arrived: 1
        default: 0
        }
    }

    private var isLive: Bool {
        guard let check = presentation.train.lastSuccessfulCheck, !presentation.train.lastRefreshFailed,
              presentation.train.arrival?.isEstimated == true else { return false }
        return presentation.date.timeIntervalSince(check) <= 5 * 60
    }
}

/// The ticket's dotted tear line.
struct NextTrainPerforation: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Line()
            .stroke(NextTrainInk(renderingMode).rail, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 4]))
            .frame(height: 1)
            .accessibilityHidden(true)
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

extension WidgetTrainPresentation {
    /// The time the widget should show as its anchor, struck through when cancelled.
    func anchorText(font: Font) -> some View {
        Text(anchorTimeText)
            .font(font)
            .monospacedDigit()
            .strikethrough(status == .cancelled)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}
