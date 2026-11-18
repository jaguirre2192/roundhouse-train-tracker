import SwiftUI
import TrainTrackerCore
import UIKit

/// Loads the photo for the named place on demand. Status updates that retain the same
/// lookup key never start another request.
struct CityPhotoLoader: ViewModifier {
    @Environment(\.cityPhotoStore) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let query: CityPhotoQuery?
    @Binding var loaded: LoadedCityPhoto?

    func body(content: Content) -> some View {
        content.task(id: query) {
            guard let query else {
                loaded = nil
                return
            }
            if loaded?.key != query.key { loaded = nil }
            guard loaded == nil else { return }
            guard let photo = await store.photo(for: query) else { return }
            let image = await UIImage(data: photo.imageData)?.byPreparingForDisplay()
            guard !Task.isCancelled, let image else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                loaded = LoadedCityPhoto(key: query.key, credit: photo.credit, image: image)
            }
        }
    }
}

struct LoadedCityPhoto: Equatable {
    let key: String
    let credit: CityPhotoCredit
    let image: UIImage
}

extension View {
    func cityPhoto(for query: CityPhotoQuery?, into loaded: Binding<LoadedCityPhoto?>) -> some View {
        modifier(CityPhotoLoader(query: query, loaded: loaded))
    }
}
