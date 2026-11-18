import SwiftUI

/// Each native form keeps its own scroll position; the Settings owner retains preferences,
/// account actions and presentations when the available width changes.
struct SettingsColumnsLayout<Account: View, Preferences: View>: View {
  let columns: SettingsLayoutGeometry.Columns
  @ViewBuilder var account: () -> Account
  @ViewBuilder var preferences: () -> Preferences

  var body: some View {
    HStack(alignment: .top, spacing: columns.gap) {
      account()
        .modifier(SettingsColumnStyle())
        .frame(width: columns.accountWidth)
        .accessibilityIdentifier("settingsAccountColumn")

      preferences()
        .modifier(SettingsColumnStyle())
        .frame(width: columns.preferencesWidth)
        .accessibilityIdentifier("settingsPreferencesColumn")
    }
    .labelStyle(SettingsTileLabelStyle())
    .padding(.horizontal, SettingsLayoutGeometry.outerInset)
    .frame(width: columns.width)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Two readable grouped forms fit on the unfolded display without stretching the pass.
/// Active vertical folds set the exact pane boundary; larger type requires more room.
struct SettingsLayoutGeometry {
  struct Columns {
    let accountWidth: CGFloat
    let preferencesWidth: CGFloat
    let gap: CGFloat
    var width: CGFloat { accountWidth + preferencesWidth + gap + 2 * SettingsLayoutGeometry.outerInset }
  }

  let space: JourneyPanelGeometry
  let minimumColumnWidth: CGFloat
  let usesAccessibilityType: Bool

  static let columnMargin = TrainTrackerSpacing.space12
  static let outerInset = LayoutMetrics.pageInset - columnMargin
  private static let maximumWidth: CGFloat = 1100

  var columns: Columns? {
    guard !usesAccessibilityType else { return nil }
    if let leading = space.leadingFoldBoundary, let trailing = space.trailingFoldBoundary {
      let accountWidth = leading - Self.outerInset
      let preferencesWidth = space.width - trailing - Self.outerInset
      guard min(accountWidth, preferencesWidth) >= minimumColumnWidth else { return nil }
      return Columns(accountWidth: accountWidth, preferencesWidth: preferencesWidth, gap: trailing - leading)
    }

    let width = min(space.width, Self.maximumWidth) - 2 * Self.outerInset
    guard width >= 2 * minimumColumnWidth else { return nil }
    let accountWidth = min(max(LayoutMetrics.sidePanelWidth, minimumColumnWidth), width / 2)
    return Columns(accountWidth: accountWidth, preferencesWidth: width - accountWidth, gap: 0)
  }

  /// When two columns cannot fit, keep the form in the wider usable half of an active fold.
  /// Horizontal divisions are crossed by the form's ordinary vertical scrolling.
  var singleColumnWidth: CGFloat? {
    guard let leading = space.leadingFoldBoundary, let trailing = space.trailingFoldBoundary else { return nil }
    return max(leading, space.width - trailing)
  }

  var singleColumnAlignment: Alignment {
    guard let leading = space.leadingFoldBoundary, let trailing = space.trailingFoldBoundary else { return .center }
    return leading >= space.width - trailing ? .leading : .trailing
  }
}

private struct SettingsColumnStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .contentMargins(.horizontal, SettingsLayoutGeometry.columnMargin, for: .scrollContent)
      .contentMargins(.top, TrainTrackerSpacing.space8, for: .scrollContent)
      .contentMargins(.bottom, TrainTrackerSpacing.space24, for: .scrollContent)
  }
}
