import Foundation
import SwiftUI
import TrainTrackerCore

enum RailPlacePickerSearchPolicy {
    static let debounce = Duration.milliseconds(300)

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldSearch(_ query: String) -> Bool {
        normalized(query).count >= 2
    }
}

struct RailPlacePickerPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String

    init(place: RailPlace) {
        let kindLabel: String
        switch place.kind {
        case .city:
            title = JourneySearchCopy.PlacePicker.cityTitle(place.displayName)
            kindLabel = JourneySearchCopy.PlacePicker.city
            systemImage = "building.2"
        case .station:
            title = place.displayName
            kindLabel = JourneySearchCopy.PlacePicker.station
            systemImage = TrainTrackerSymbol.train
        }

        var details = [kindLabel]
        if let context = Self.contextDetail(place) {
            details.append(context)
        }
        if !place.countryCode.isEmpty {
            details.append(
                Locale.autoupdatingCurrent.localizedString(
                    forRegionCode: place.countryCode.uppercased()
                ) ?? place.countryCode.uppercased()
            )
        }
        detail = details.joined(separator: " · ")
    }

    private static func contextDetail(_ place: RailPlace) -> String? {
        let context = place.context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty,
              context != JourneySearchCopy.PlacePicker.allStations,
              context.caseInsensitiveCompare(place.countryCode) != .orderedSame
        else { return nil }

        guard context == place.timeZoneIdentifier,
              let timeZone = TimeZone(identifier: place.timeZoneIdentifier)
        else { return context }

        let name = timeZone.localizedName(for: .generic, locale: .autoupdatingCurrent)
            ?? place.timeZoneIdentifier.replacingOccurrences(of: "_", with: " ")
        return "\(JourneySearchCopy.PlacePicker.timeZone): \(name)"
    }
}

enum RailPlacePickerRole: String, Identifiable {
    case origin
    case destination

    var id: Self { self }

    var title: String {
        switch self {
        case .origin: JourneySearchCopy.PlacePicker.chooseFrom
        case .destination: JourneySearchCopy.PlacePicker.chooseTo
        }
    }

    var searchPrompt: String {
        JourneySearchCopy.PlacePicker.searchPrompt
    }
}

@MainActor
struct RailPlacePicker: View {
    @Environment(\.dismiss) private var dismiss

    let role: RailPlacePickerRole
    let store: JourneySearchStore
    let recents: RailPlaceRecents
    /// A title for a picker that isn't filling the search form, such as Home Station.
    var title: String?
    /// When set, the chosen place goes here instead of into the search form.
    var onSelect: ((RailPlace) -> Void)?

    @State private var query = ""
    @State private var activeQuery: String?

    var body: some View {
        NavigationStack {
            List {
                pickerContent
            }
            .trainTrackerListCanvas()
            .navigationTitle(title ?? role.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(JourneySearchCopy.cancel) { dismiss() }
                }
            }
        }
        .searchable(text: $query, prompt: role.searchPrompt)
        .task(id: query) {
            await searchAfterDebounce()
        }
        .onDisappear {
            store.cancelPlaceLookup()
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        let normalizedQuery = RailPlacePickerSearchPolicy.normalized(query)
        if normalizedQuery.isEmpty {
            recentContent
        } else if !RailPlacePickerSearchPolicy.shouldSearch(normalizedQuery) {
            Section {
                ContentUnavailableView(
                    JourneySearchCopy.PlacePicker.keepTyping,
                    systemImage: "text.cursor",
                    description: Text(JourneySearchCopy.PlacePicker.minimumQuery)
                )
            }
            .trainTrackerRowSurface()
        } else if activeQuery != normalizedQuery || store.isPlaceLookupTaskActive {
            Section {
                HStack(spacing: TrainTrackerSpacing.space12) {
                    ProgressView().controlSize(.small)
                    Text(JourneySearchCopy.PlacePicker.searching)
                        .foregroundStyle(Color.ttTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            .trainTrackerRowSurface()
        } else if store.placeLookupFailed {
            Section {
                Label(
                    JourneySearchCopy.PlacePicker.failure,
                    systemImage: "wifi.exclamationmark"
                )
                .foregroundStyle(Color.ttStatusDelayed)

                Button(JourneySearchCopy.PlacePicker.tryAgain, action: retrySearch)
                    .accessibilityLabel(JourneySearchCopy.Accessibility.retryPlaceSearch.label)
                    .accessibilityHint(JourneySearchCopy.Accessibility.retryPlaceSearch.hint)
            }
            .trainTrackerRowSurface()
        } else if store.placeResults.isEmpty {
            Section {
                ContentUnavailableView.search(text: query)
            }
            .trainTrackerRowSurface()
        } else {
            Section(JourneySearchCopy.PlacePicker.places) {
                ForEach(store.placeResults) { place in
                    placeButton(place)
                }
            }
            .trainTrackerRowSurface()
        }
    }

    @ViewBuilder
    private var recentContent: some View {
        if recents.places.isEmpty {
            Section {
                ContentUnavailableView(
                    JourneySearchCopy.PlacePicker.emptyTitle,
                    systemImage: "magnifyingglass",
                    description: Text(JourneySearchCopy.PlacePicker.emptyDescription)
                )
            }
            .trainTrackerRowSurface()
        } else {
            Section(JourneySearchCopy.PlacePicker.recent) {
                ForEach(recents.places.prefix(6)) { place in
                    placeButton(place)
                }

                Button(JourneySearchCopy.PlacePicker.clearRecents, role: .destructive) {
                    recents.clearPlaces()
                }
                .accessibilityLabel(JourneySearchCopy.Accessibility.clearRecents.label)
                .accessibilityHint(JourneySearchCopy.Accessibility.clearRecents.hint)
            }
            .trainTrackerRowSurface()
        }
    }

    private func placeButton(_ place: RailPlace) -> some View {
        let presentation = RailPlacePickerPresentation(place: place)
        return Button {
            select(place)
        } label: {
            HStack(alignment: .top, spacing: TrainTrackerSpacing.space12) {
                Image(ttSymbol: presentation.systemImage)
                    .frame(width: LayoutMetrics.iconRailWidth)
                    .foregroundStyle(Color.ttRouteActive)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: TrainTrackerSpacing.space4) {
                    Text(presentation.title)
                        .foregroundStyle(Color.ttTextPrimary)
                    Text(presentation.detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.ttTextSecondary)
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presentation.title), \(presentation.detail)")
    }

    private func searchAfterDebounce() async {
        store.cancelPlaceLookup()
        activeQuery = nil
        let candidate = RailPlacePickerSearchPolicy.normalized(query)
        guard RailPlacePickerSearchPolicy.shouldSearch(candidate) else { return }

        do {
            try await Task.sleep(for: RailPlacePickerSearchPolicy.debounce)
        } catch is CancellationError {
            return
        } catch {
            return
        }
        guard !Task.isCancelled,
              candidate == RailPlacePickerSearchPolicy.normalized(query) else { return }
        activeQuery = candidate
        store.lookupPlaces(query: candidate)
    }

    private func retrySearch() {
        let candidate = RailPlacePickerSearchPolicy.normalized(query)
        guard RailPlacePickerSearchPolicy.shouldSearch(candidate) else { return }
        store.cancelPlaceLookup()
        activeQuery = candidate
        store.lookupPlaces(query: candidate)
    }

    private func select(_ place: RailPlace) {
        if let onSelect {
            onSelect(place)
            dismiss()
            return
        }
        switch role {
        case .origin:
            store.setOrigin(place)
        case .destination:
            store.setDestination(place)
        }
        recents.record(place)
        dismiss()
    }
}
