import SwiftUI

/// The one inline callout for service disruption, paused updates, storage problems and other
/// non-blocking issues. Background failures use a notice, never a modal alert.
struct TrainTrackerNotice<Actions: View>: View {
    enum Tone {
        case informational
        case warning
        case critical

        var color: Color {
            switch self {
            case .informational: .ttTextOperational
            case .warning: .ttStatusDelayed
            case .critical: .ttStatusCancelled
            }
        }

        /// A wash over the frosted surface. Only a critical notice tints its whole card.
        var wash: Color {
            switch self {
            case .informational, .warning: .clear
            case .critical: Color.ttStatusCancelled.opacity(0.12)
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(TrainTrackerPreference.background) private var page = BackgroundPreference.standard

    let tone: Tone
    let title: String
    let message: String?
    let systemImage: String
    @ViewBuilder let actions: () -> Actions

    init(
        _ title: String,
        message: String? = nil,
        systemImage: String = "exclamationmark.triangle.fill",
        tone: Tone = .warning,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tone = tone
        self.actions = actions
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
                    icon
                    content
                }
            } else {
                HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                    icon
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TrainTrackerSpacing.space16)
        // Frosted like the rows around it, so it takes the page's color instead of sitting on
        // it as a pale box; the tone lives on the symbol.
        .background(tone.wash, in: RoundedRectangle(cornerRadius: TrainTrackerRadius.control, style: .continuous))
        .background(
            Color.ttSurfaceOnWash(solid: reduceTransparency || contrast == .increased, page: page),
            in: RoundedRectangle(cornerRadius: TrainTrackerRadius.control, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.footnote.weight(.bold))
            .foregroundStyle(tone.color)
            .frame(width: 30, height: 30)
            .background(tone.color.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ttTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.ttTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Actions.self != EmptyView.self {
                actions()
                    .buttonStyle(.bordered)
                    .padding(.top, TrainTrackerSpacing.space4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension TrainTrackerNotice where Actions == EmptyView {
    init(_ title: String, message: String? = nil, systemImage: String = "exclamationmark.triangle.fill", tone: Tone = .warning) {
        self.init(title, message: message, systemImage: systemImage, tone: tone) { EmptyView() }
    }
}

extension View {
    /// A full-width label for a prominent or bordered action inside a card or form. The frame
    /// belongs on the label so the button's own shape fills the width, not just its hit area.
    func trainTrackerFullWidthAction() -> some View {
        frame(maxWidth: .infinity, minHeight: 44)
    }

    /// Keeps the last row of a tab-root form above the floating tab bar, matching Settings and
    /// search results.
    func trainTrackerTabBarClearance() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: LayoutMetrics.mobileFloatingBarClearance)
                .accessibilityHidden(true)
        }
    }

    /// A grouped-form row that carries a full-width action or notice instead of a cell: no cell
    /// background, no insets, no separator. Keeps Search, Add Journey and review forms aligned.
    func trainTrackerFormActionRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
