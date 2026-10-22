import SwiftUI

struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""
    @State private var showingRename = false

    private var favorites: [SavedPlace] { filtered(session.favorites) }
    private var recents: [SavedPlace] { filtered(session.recents) }
    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if !isFiltering || !favorites.isEmpty {
                    Section {
                        if favorites.isEmpty {
                            ContentUnavailableView {
                                Label("Keep a place close", systemImage: "star")
                            } description: {
                                Text("Save a recent place using its menu, or star a pin on the map.")
                            }
                        }
                        ForEach(favorites) { place in
                            placeRow(place, favoriteSection: true)
                        }
                    } header: {
                        sectionHeader("Favorites", symbol: "star.fill", count: favorites.count)
                    }
                }

                if !isFiltering || !recents.isEmpty {
                    Section {
                        if recents.isEmpty {
                            ContentUnavailableView {
                                Label("Somewhere new awaits", systemImage: "clock.arrow.circlepath")
                            } description: {
                                Text("Places you search for or teleport to will appear here.")
                            }
                        }
                        ForEach(recents) { place in
                            placeRow(place, favoriteSection: false)
                        }
                    } header: {
                        sectionHeader("Recents", symbol: "clock", count: recents.count)
                    } footer: {
                        if !recents.isEmpty && !isFiltering { Text("Most recent first · Up to 20 places") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if isFiltering && favorites.isEmpty && recents.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter by name or coordinates")
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .tint(LocusTheme.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: $showingRename) {
                TextField("Place name", text: $renameText)
                Button("Cancel", role: .cancel) { placeToRename = nil }
                Button("Save", action: saveRename)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
        }
    }

    private func sectionHeader(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(count, format: .number).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func placeRow(_ place: SavedPlace, favoriteSection: Bool) -> some View {
        PlaceRow(
            place: place,
            isFavorite: session.isFavorite(place),
            isFavoriteSection: favoriteSection,
            onTeleport: { teleport(to: place) },
            onToggleFavorite: { session.toggleFavorite(place) },
            onRename: { beginRename(place) },
            onRemoveRecent: { session.removeRecent(place) }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if favoriteSection {
                Button("Remove", systemImage: "star.slash", role: .destructive) {
                    session.removeFavorite(place)
                }
                .tint(LocusTheme.danger)
                Button("Rename", systemImage: "pencil") { beginRename(place) }
                    .tint(LocusTheme.accent)
            } else {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    session.removeRecent(place)
                }
                .tint(LocusTheme.danger)
            }
        }
    }

    private func filtered(_ places: [SavedPlace]) -> [SavedPlace] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return places }
        return places.filter {
            $0.name.localizedStandardContains(term)
                || String(format: "%.5f, %.5f", $0.latitude, $0.longitude).localizedStandardContains(term)
        }
    }

    private func teleport(to place: SavedPlace) {
        session.teleport(to: place.coordinate, pairing: pairing)
        dismiss()
    }

    private func beginRename(_ place: SavedPlace) {
        // History may still contain the original name of a renamed favorite.
        placeToRename = session.favorites.first { $0.id == place.id }
        renameText = placeToRename?.name ?? place.name
        showingRename = true
    }

    private func saveRename() {
        if let placeToRename { session.renameFavorite(placeToRename, to: renameText) }
        placeToRename = nil
    }
}
