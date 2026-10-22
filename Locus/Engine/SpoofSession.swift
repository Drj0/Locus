import CoreLocation
import Foundation
import MapKit
import Network
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    /// Teleport is in progress. Published only when the Teleport button is showing (not spoofing):
    /// joystick ticks and route steps would otherwise re-render every observer twice per step.
    @Published var isBusy = false
    private var engineBusy = false
    @Published var joystickActive = false
    /// A teleport failed because mobile data is the only route; it runs once data is off.
    @Published var awaitingDataOff = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []
    /// Places picked from search, newest first, for quick re-selection.
    @Published var recentSearches: [SavedPlace] = []

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()
    /// Bumped by Stop so an engine call that finishes afterwards doesn't revive the session.
    private var generation = 0
    private let pathMonitor = NWPathMonitor()
    /// Mobile data is up with no Wi‑Fi / Ethernet. iOS refuses new developer tunnels then.
    private var cellularOnly = false
    private var pendingTeleport: (coordinate: CLLocationCoordinate2D, markRecent: Bool)?
    private weak var activePairing: PairingStore?

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"
    private let recentSearchesKey = "locus.recentSearches"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
        recentSearches = SavedPlace.load(key: recentSearchesKey)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let types = path.availableInterfaces.map(\.type)
            let cellularOnly = types.contains(.cellular) && !types.contains(.wifi) && !types.contains(.wiredEthernet)
            Task { @MainActor in self?.routeChanged(cellularOnly: cellularOnly) }
        }
        pathMonitor.start(queue: .main)
    }

    func retryAfterDataOff() {
        guard let pending = pendingTeleport, let pairing = activePairing else { return }
        // Let the alert dismiss first so a repeat failure can present it again.
        awaitingDataOff = false
        Task { [weak self] in
            await self?.apply(pending.coordinate, pairing: pairing, markRecent: pending.markRecent)
        }
    }

    func cancelDataOffWait() {
        awaitingDataOff = false
        pendingTeleport = nil
    }

    private func routeChanged(cellularOnly: Bool) {
        let freed = self.cellularOnly && !cellularOnly
        self.cellularOnly = cellularOnly
        guard freed else { return }
        Task { @MainActor [weak self] in
            // Give the device a moment to bring its pairing listener up.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.cellularOnly, let pairing = self.activePairing else { return }
            if self.pendingTeleport != nil {
                self.retryAfterDataOff()
            } else if self.status.isDropped, let sim = self.simulated {
                self.status = .reconnecting
                await self.apply(sim, pairing: pairing, markRecent: false)
            }
        }
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        pin = coordinate
        Task { await apply(coordinate, pairing: pairing, markRecent: true) }
    }

    func stop(pairing: PairingStore) {
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        stopHealth()
        // Results of teleports still in flight belong to the session being stopped.
        generation += 1
        Task { await finishStop() }
    }

    private func finishStop() async {
        isBusy = true
        let result = await LocationEngine.clear()
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            status = .idle
            endBackground()
            // Keep location updates running so the map puck / locate button
            // can return to the real GPS fix (not the leftover pin).
            locationKeeper.start(inBackground: false)
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription)
        }
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start(inBackground: isSpoofing)
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        if simulated == nil {
            Task { await apply(start, pairing: pairing, markRecent: false) }
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self else { return }
            var previous = coordinates[0]
            await self.apply(previous, pairing: pairing, markRecent: true)
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await self.apply(coord, pairing: pairing, markRecent: false)
                }
                previous = next
            }
        }
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func isFavorite(_ place: SavedPlace) -> Bool {
        favorites.contains { $0.id == place.id }
    }

    func toggleFavorite(_ place: SavedPlace) {
        if isFavorite(place) {
            removeFavorite(place)
        } else {
            addFavorite(name: place.name, coordinate: place.coordinate)
        }
    }

    func pushRecentSearch(name: String, coordinate: CLLocationCoordinate2D) {
        let place = SavedPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
        recentSearches.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recentSearches.insert(place, at: 0)
        if recentSearches.count > 8 { recentSearches = Array(recentSearches.prefix(8)) }
        SavedPlace.save(recentSearches, key: recentSearchesKey)
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        SavedPlace.save(recentSearches, key: recentSearchesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) async {
        let wasActive = status == .active
        let generation = generation
        activePairing = pairing
        if status == .idle || status.isDropped {
            status = .connecting
        }
        let showsProgress = !isSpoofing
        engineBusy = true
        if showsProgress { isBusy = true }
        let result = await LocationEngine.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: TunnelConfig.targetIP
        )
        engineBusy = false
        if isBusy { isBusy = false }
        guard generation == self.generation else { return }
        switch result {
        case .success:
            simulated = coordinate
            pin = coordinate
            status = .active
            lastError = nil
            if pendingTeleport != nil {
                cancelDataOffWait()
                lastError = "Spoofing. You can turn Mobile Data back on — the session keeps running."
            }
            beginBackground()
            locationKeeper.start(inBackground: true)
            startResend(pairing: pairing)
            startHealth(pairing: pairing)
            if markRecent {
                pushRecent(coordinate)
            }
        case .failure(let error):
            var blockedByMobileData = false
            if case .tunnelCreate = error { blockedByMobileData = cellularOnly }
            let message = blockedByMobileData ? Self.mobileDataHint : error.localizedDescription
            if simulated != nil {
                lastError = message
                // Notify only when a live spoof drops. Retries (health check, joystick ticks,
                // route steps) start from .dropped / .reconnecting and would otherwise repeat it.
                if wasActive {
                    postDropNotification(message)
                }
                status = .dropped(message)
            } else if blockedByMobileData {
                pendingTeleport = (coordinate, markRecent)
                awaitingDataOff = true
                status = .idle
            } else {
                lastError = message
                cancelDataOffWait()
                status = .idle
            }
        }
    }

    private static let mobileDataHint = "Mobile data blocks the developer tunnel. Keep LocalDevVPN connected and turn Mobile Data off (or Airplane Mode on) for a few seconds — Locus connects by itself, then turn it back on."

    private func tickJoystick(pairing: PairingStore) {
        // Skip a tick while the engine is still busy so moves don't queue up behind it.
        guard joystickActive, !engineBusy, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        Task { await apply(next, pairing: pairing, markRecent: false) }
    }

    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                let result = await LocationEngine.set(
                    latitude: sim.latitude,
                    longitude: sim.longitude,
                    pairingPath: pairing.pairingPath,
                    deviceIP: TunnelConfig.targetIP
                )
                // The tunnel can die silently (e.g. Wi‑Fi → cellular); stop claiming "Spoofing"
                // so the health check takes over reconnecting.
                if case .failure(let error) = result, self.status == .active {
                    self.status = .dropped(error.localizedDescription)
                    self.postDropNotification(error.localizedDescription)
                }
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                if case .dropped = self.status {
                    self.status = .reconnecting
                    await self.apply(sim, pairing: pairing, markRecent: false)
                } else if !LocationEngine.isSessionActive, self.isSpoofing {
                    self.status = .reconnecting
                    await self.apply(sim, pairing: pairing, markRecent: false)
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
