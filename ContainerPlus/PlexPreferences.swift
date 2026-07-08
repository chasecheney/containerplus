import Foundation
import Combine

/// Persisted Plex UI preferences shared across panes: the user's favorite
/// libraries (ordered) that appear at the top of the library picker.
final class PlexPreferences: ObservableObject {
    static let shared = PlexPreferences()

    @Published private(set) var favorites: [PlexLibraryRef] = []

    private let favoritesKey = "plex.favoriteLibraries"

    private init() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([PlexLibraryRef].self, from: data) {
            favorites = decoded
        }
    }

    func isFavorite(_ ref: PlexLibraryRef) -> Bool {
        favorites.contains { $0.id == ref.id }
    }

    func toggleFavorite(_ ref: PlexLibraryRef) {
        if let index = favorites.firstIndex(where: { $0.id == ref.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(ref)
        }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }
}
