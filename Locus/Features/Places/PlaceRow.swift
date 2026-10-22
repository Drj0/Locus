import SwiftUI

struct PlaceRow: View {
    let place: SavedPlace
    let isFavorite: Bool
    let isFavoriteSection: Bool
    let onTeleport: () -> Void
    let onToggleFavorite: () -> Void
    let onRename: () -> Void
    let onRemoveRecent: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onTeleport) {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: isFavoriteSection ? "star.fill" : "mappin.and.ellipse")
                            .font(.title3)
                            .foregroundStyle(LocusTheme.accent)
                            .frame(width: 44, height: 44)
                            .background(LocusTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(place.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if isFavorite && !isFavoriteSection {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(LocusTheme.statusWarn)
                            }
                        }
                        Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(Image(systemName: "location.fill")) Teleport")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LocusTheme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Teleport to \(place.name)")
            .accessibilityValue((isFavorite && !isFavoriteSection ? "Favorite, " : "")
                + String(format: "%.5f, %.5f", place.latitude, place.longitude))

            Menu {
                Button(isFavorite ? "Remove from Favorites" : "Save to Favorites",
                       systemImage: isFavorite ? "star.slash" : "star",
                       action: onToggleFavorite)
                if isFavorite {
                    Button("Rename Favorite", systemImage: "pencil", action: onRename)
                }
                if !isFavoriteSection {
                    Button("Remove from Recents", systemImage: "trash", role: .destructive, action: onRemoveRecent)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Options for \(place.name)")
        }
    }
}
