#if DEBUG
import SwiftUI
import TrainTrackerCore
import WidgetKit

/// `-WidgetPreview [-WidgetPreviewState <state>] [-WidgetPreviewMode tinted]`: every widget
/// family for one state at real iPhone 17 Pro family sizes, for screenshots. Home Screen tiles
/// draw the ink background themselves because `containerBackground` only applies in WidgetKit.
struct WidgetPreviewScene: View {
    @State private var state: NextTrainWidgetSamples.State
    private let tinted: Bool
    private let referenceDate: Date

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        _state = State(initialValue: value(after: "-WidgetPreviewState").flatMap(NextTrainWidgetSamples.State.init(rawValue:)) ?? .sample)
        tinted = value(after: "-WidgetPreviewMode") == "tinted"
        referenceDate = Calendar.current.date(bySettingHour: 17, minute: 55, second: 0, of: .now) ?? .now
    }

    private var entry: NextTrainEntry {
        NextTrainEntry(
            date: referenceDate,
            snapshot: NextTrainWidgetSamples.snapshot(for: state, at: referenceDate),
            source: state == .sample ? .sample : .live
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("State", selection: $state) {
                    ForEach(NextTrainWidgetSamples.State.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("widgetPreviewState")

                homeScreen
                lockScreen
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            // By day, by night, then as the system's glass.
            HStack(spacing: 16) {
                tile(.systemSmall, mode: tinted ? .accented : .fullColor)
                tile(.systemSmall, mode: tinted ? .accented : .fullColor, scheme: .dark)
            }
            tile(.systemMedium, mode: tinted ? .accented : .fullColor)
            tile(.systemMedium, mode: tinted ? .accented : .fullColor, scheme: .dark)
            HStack(spacing: 16) {
                tile(.systemSmall, mode: .accented)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.85, green: 0.91, blue: 0.93), Color(red: 0.55, green: 0.70, blue: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }

    private func tile(_ family: WidgetFamily, mode: WidgetRenderingMode, scheme fullColorScheme: ColorScheme = .light) -> some View {
        let size = family == .systemMedium ? CGSize(width: 338, height: 158) : CGSize(width: 158, height: 158)
        return NextTrainWidgetView(entry: entry, family: family)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .environment(\.widgetRenderingMode, mode)
            .background {
                if mode == .fullColor {
                    NextTrainTicketBackground()
                } else {
                    // Tinted and clear appearances replace the page with system material.
                    Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                }
            }
            .environment(\.colorScheme, mode == .fullColor ? fullColorScheme : .dark)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityIdentifier("widgetPreview-\(family)-\(mode)\(fullColorScheme == .dark && mode == .fullColor ? "-dark" : "")")
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            NextTrainWidgetView(entry: entry, family: .accessoryInline)
                .font(.subheadline.weight(.medium))
                .frame(width: 257, height: 26, alignment: .leading)
            HStack(spacing: 12) {
                NextTrainWidgetView(entry: entry, family: .accessoryRectangular)
                    .frame(width: 172, height: 76, alignment: .leading)
                NextTrainWidgetView(entry: entry, family: .accessoryCircular)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
        }
        .environment(\.widgetRenderingMode, .vibrant)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.36), Color(red: 0.42, green: 0.30, blue: 0.40)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }
}
#endif
