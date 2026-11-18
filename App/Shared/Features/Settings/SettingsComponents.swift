import SwiftUI

/// Who is travelling, printed on the same ink stock as a live ticket: the name or Guest above
/// the perforation, what is saved on this device on the stub.
struct SettingsPassCard: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let name: String
  let caption: String
  let stamp: String
  let fields: [TicketStubField]
  /// Seeds the decorative code bars, so the card keeps one pattern per traveller.
  let seed: String

  private let secondaryOnInk = Color.ttTextOnBrand.opacity(0.72)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: TrainTrackerSpacing.space16) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: TrainTrackerSpacing.space12) {
            wordmark
            Spacer(minLength: 0)
            passStamp
          }
          VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
            wordmark
            passStamp
          }
        }
        HStack(alignment: .bottom, spacing: TrainTrackerSpacing.space12) {
          VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
            Text(name)
              .font(.largeTitle.weight(.bold))
              .foregroundStyle(Color.ttTextOnBrand)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
              .minimumScaleFactor(0.7)
            Text(caption)
              .font(.subheadline)
              .foregroundStyle(secondaryOnInk)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !dynamicTypeSize.isAccessibilitySize {
            Spacer(minLength: 0)
            TicketCodeBars(seed: seed)
          }
        }
      }
      .padding(LayoutMetrics.cardInset)

      TicketPerforation.onInk

      TicketStubGrid(fields: fields, labelColor: secondaryOnInk, valueColor: .ttTextOnBrand)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutMetrics.cardInset)
    }
    .liveTicketStyle()
    .accessibilityElement(children: .combine)
  }

  private var wordmark: some View {
    RoundhouseWordmark()
      .foregroundStyle(Color.ttTextOnBrand)
  }

  private var passStamp: some View {
    Text(stamp)
      .font(.caption2.weight(.bold))
      .textCase(.uppercase)
      .tracking(1)
      .foregroundStyle(Color.ttTextOnBrand)
      .padding(.horizontal, TrainTrackerSpacing.space8)
      .padding(.vertical, TrainTrackerSpacing.space4)
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(secondaryOnInk, lineWidth: TrainTrackerStroke.subtle)
      }
      .fixedSize()
  }
}

/// One thing the system decides for Train Tracker (alerts, Live Activities), with its current
/// state. Tapping opens the place where it can be changed.
struct SettingsStatusTile: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @AppStorage(TrainTrackerPreference.background) private var page = BackgroundPreference.standard

  let systemImage: String
  let title: String
  let value: String
  let tint: Color
  let hint: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
        HStack(alignment: .top) {
          Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
          Spacer(minLength: 0)
          Image(systemName: "arrow.up.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.ttTextSecondary)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
          Text(title)
            .font(.subheadline)
            .foregroundStyle(Color.ttTextSecondary)
          Text(value)
            .font(.headline)
            .foregroundStyle(Color.ttTextPrimary)
            .contentTransition(.opacity)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(TrainTrackerSpacing.space16)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .background(
        Color.ttSurfaceOnWash(solid: reduceTransparency || contrast == .increased, page: page),
        in: RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: TrainTrackerRadius.card, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(value)")
    .accessibilityHint(hint)
  }
}

/// Settings rows carry their symbol on a small ink tile, so every group reads as one printed set.
struct SettingsTileLabelStyle: LabelStyle {
  @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: TrainTrackerSpacing.space12) {
      configuration.icon
        .font(.system(size: side * 0.48, weight: .semibold))
        .foregroundStyle(Color.ttTextOnBrand)
        .frame(width: side, height: side)
        .background(
          Color.ttBackgroundBrand,
          in: RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
        )
        .accessibilityHidden(true)
      configuration.title
    }
  }
}

/// A row title with a line of explanation beneath it.
struct SettingsRowTitle: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
      Text(title)
        .foregroundStyle(Color.ttTextPrimary)
      Text(detail)
        .font(.footnote)
        .foregroundStyle(Color.ttTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
