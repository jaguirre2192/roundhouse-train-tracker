import SwiftUI

struct TrainTrackerDataAndCoverageSection: View {
  private var sources: [JourneyDataSourceLink] {
    JourneyDataSources.settings + JourneyDataSources.additional
  }

  var body: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space2) {
          Text("United States and International Rail")
            .foregroundStyle(Color.ttTextPrimary)
          Text("Schedule, live, position, and platform coverage varies by operator.")
            .font(.subheadline)
            .foregroundStyle(Color.ttTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(systemName: "network")
          .foregroundStyle(Color.ttRouteActive)
      }

      Link(destination: JourneyDataSources.coverageURL) {
        Label("View Current Coverage", systemImage: "checkmark.seal")
      }

      DisclosureGroup {
        VStack(alignment: .leading, spacing: TrainTrackerSpacing.space8) {
          ForEach(sources) { source in
            Link(destination: source.destination) {
              Text(source.title)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint(JourneyDataSources.linkHint(source.title))
          }
        }
        .padding(.top, TrainTrackerSpacing.space6)
      } label: {
        Label("Data Sources & Attribution", systemImage: "building.columns")
      }
    } header: {
      Text("Data & Coverage")
    } footer: {
      VStack(alignment: .leading, spacing: TrainTrackerSpacing.space6) {
        Text(JourneyDataSources.qualification)
        Text("Confirm critical travel information with the train operator.")
      }
      .foregroundStyle(Color.ttTextPrimary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .trainTrackerRowSurface()
  }
}

enum TrainTrackerSettingsLinks {
  static let source = URL(string: "https://github.com/jaguirre2192/roundhouse-train-tracker")!
  static let privacy = URL(
    string: "https://gettraintracker.com/privacy"
  )!
  static let support = URL(
    string: "https://gettraintracker.com/support"
  )!
  static let website = URL(
    string: "https://gettraintracker.com"
  )!
}
