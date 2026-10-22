import SwiftUI
import NetworkExtension

struct RootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @State private var showSettings = false
    @State private var showPlaces = false

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
            MapHomeView()
                .alert("Turn Off Mobile Data", isPresented: Binding(
                    get: { session.awaitingDataOff },
                    set: { _ in }  // the buttons below decide
                )) {
                    Button("Try Again") { session.retryAfterDataOff() }
                    Button("Cancel", role: .cancel) { session.cancelDataOffWait() }
                } message: {
                    Text("iOS won’t open the developer tunnel while mobile data is your only connection. Keep LocalDevVPN connected and turn Mobile Data off (or Airplane Mode on) for a few seconds. Locus teleports by itself, then you can turn it back on.")
                }

            BottomControlsView(
                showSettings: $showSettings,
                showPlaces: $showPlaces
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .alert("Locus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { _ in }  // OK clears lastError; writing it here would publish during a view update
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

/// LocalDevVPN state, polled while the app is active. Publishes only on change.
@MainActor
final class TunnelMonitor: ObservableObject {
    @Published private(set) var connected = LocalDevVPN.isConnected
    @Published private(set) var installed = LocalDevVPN.isInstalled

    /// `includeInstall` asks LaunchServices (an IPC round trip) whether LocalDevVPN is installed,
    /// which can only change while Locus is in the background, so the 2 s poll skips it.
    func refresh(includeInstall: Bool = false) {
        let connected = LocalDevVPN.isConnected
        if connected != self.connected { self.connected = connected }
        guard includeInstall else { return }
        let installed = LocalDevVPN.isInstalled
        if installed != self.installed { self.installed = installed }
    }

    /// Something the user must act on: no tunnel, or the spoof dropped. `.reconnecting` counts
    /// too: the health check alternates it with `.dropped`, which would otherwise flicker the banner.
    func needsAttention(_ status: SpoofStatus) -> Bool {
        !connected || status.isDropped || status == .reconnecting
    }
}

private struct TunnelMonitoring: ViewModifier {
    @ObservedObject var monitor: TunnelMonitor
    let status: SpoofStatus
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.refresh(includeInstall: true) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { monitor.refresh(includeInstall: true) }
            }
            .onChange(of: status) { _, _ in monitor.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
                // LocalDevVPN connection changes show up here even though we don’t own the VPN.
                monitor.refresh()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    monitor.refresh()
                }
            }
    }
}

extension View {
    func monitoringTunnel(_ monitor: TunnelMonitor, status: SpoofStatus) -> some View {
        modifier(TunnelMonitoring(monitor: monitor, status: status))
    }
}

/// Full-width, tinted: shown only when the tunnel is off or the spoof dropped.
/// Amber for VPN off (a running spoof keeps working for a while without it); red for a drop.
struct VPNAttentionBanner: View {
    @EnvironmentObject private var session: SpoofSession
    @ObservedObject var monitor: TunnelMonitor
    @Binding var expanded: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dropped: Bool { monitor.connected }

    private var tint: Color { dropped ? LocusTheme.statusBad : LocusTheme.statusWarn }

    private var title: String {
        dropped ? "Location spoof dropped" : "LocalDevVPN is off"
    }

    private var subtitle: String {
        if !dropped {
            return session.simulated == nil ? "Connect it to teleport" : "Connect it to move or change location"
        }
        return session.status == .reconnecting ? "Reconnecting…" : "Locus keeps retrying · tap for details"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: dropped ? "exclamationmark.shield.fill" : "shield.slash.fill")
                        .font(.title3)
                        .foregroundStyle(tint)
                        // Only a drop pulses; "VPN off" stays still.
                        .symbolEffect(.pulse, options: .repeating, isActive: dropped && !expanded)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // One line normally; wrap at accessibility sizes instead of truncating.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(subtitle)")
            .accessibilityHint(expanded ? "Hides connection details" : "Shows connection details")

            if !monitor.connected {
                Button(monitor.installed ? "Connect" : "Get") {
                    LocalDevVPN.openOrInstall()
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(LocusTheme.accent))
                .contentShape(Capsule())
                .buttonStyle(.plain)
                .accessibilityLabel(monitor.installed ? "Connect LocalDevVPN" : "Get LocalDevVPN")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .locusGlass(.regular, tint: tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Icon-only: shown beside the locate button while the tunnel is fine. Outline when idle,
/// filled green while spoofing, pulsing amber while a teleport starts.
struct VPNStatusChip: View {
    @EnvironmentObject private var session: SpoofSession
    @Binding var expanded: Bool

    private var isBusy: Bool { session.status == .connecting }

    private var symbol: String {
        switch session.status {
        case .active: return "checkmark.shield.fill"
        case .connecting: return "shield.fill"
        default: return "checkmark.shield"
        }
    }

    private var tint: Color {
        switch session.status {
        case .active: return LocusTheme.statusGood
        case .connecting: return LocusTheme.statusWarn
        default: return .secondary
        }
    }

    private var label: String {
        switch session.status {
        case .active: return "LocalDevVPN connected, spoofing"
        case .connecting: return "LocalDevVPN connected, starting spoof"
        default: return "LocalDevVPN connected, not spoofing"
        }
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: isBusy)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, tint: expanded ? LocusTheme.accent.opacity(0.35) : nil, in: Circle())
        .contentShape(Circle())
        .accessibilityLabel(label)
        .accessibilityHint(expanded ? "Hides connection details" : "Shows connection details")
    }
}

struct VPNStatusDetails: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @ObservedObject var monitor: TunnelMonitor

    private var locationText: String {
        switch session.status {
        case .idle: return "Real location"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Dropped"
        }
    }

    private var locationTint: Color? {
        switch session.status {
        case .idle: return nil
        case .active: return LocusTheme.statusGood
        case .connecting, .reconnecting: return LocusTheme.statusWarn
        case .dropped: return LocusTheme.statusBad
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow("LocalDevVPN", value: monitor.connected ? "Connected" : "Not connected",
                      tint: monitor.connected ? LocusTheme.statusGood : LocusTheme.statusWarn)
            detailRow("Device IP", value: TunnelConfig.targetIP, monospaced: true)
            detailRow("Location", value: locationText, tint: locationTint)
            if let sim = session.simulated, session.isSpoofing {
                detailRow("Coordinates", value: String(format: "%.5f, %.5f", sim.latitude, sim.longitude), monospaced: true)
            }
            detailRow("Pairing file", value: pairing.hasPairingFile ? "Imported" : "Missing",
                      tint: pairing.hasPairingFile ? nil : LocusTheme.statusWarn)

            if let hint = troubleshooting {
                Label(hint, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var troubleshooting: String? {
        if case .dropped(let reason) = session.status, !reason.isEmpty {
            return reason
        }
        if LocalDevVPN.isOwnAddress(TunnelConfig.targetIP) {
            return "The Device IP is this iPhone’s own address (LocalDevVPN’s Tunnel IP). Enter LocalDevVPN’s Device IP in Settings."
        }
        if !monitor.connected {
            return "Connected but still off here? Locus needs LocalDevVPN’s Device IP (default \(TunnelConfig.defaultIP)), not its Tunnel IP — change it in Settings."
        }
        if !pairing.hasPairingFile {
            return "Import a pairing file in Settings before teleporting."
        }
        return nil
    }

    private func detailRow(_ label: String, value: String, tint: Color? = nil, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline.weight(.semibold))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool
    @State private var showModes = false

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if showModes {
                HStack(spacing: 8) {
                    ForEach(TravelMode.allCases) { mode in
                        let selected = session.travelMode == mode
                        Button {
                            session.travelMode = mode
                            withAnimation(.snappy) { showModes = false }
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: mode.icon)
                                    .font(.body.weight(.semibold))
                                Text(mode.title)
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(selected ? .black : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(selected ? LocusTheme.accent : Color.primary.opacity(0.08))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                trayIcon("gearshape.fill") { showSettings = true }
                    .accessibilityLabel("Settings")
                trayIcon("star.fill") { showPlaces = true }
                    .accessibilityLabel("Places")

                // More options: opens the travel-mode picker.
                Button {
                    withAnimation(.snappy) { showModes.toggle() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .foregroundStyle(showModes ? .black : .primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(showModes ? LocusTheme.accent : Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Travel mode")
                .accessibilityValue(session.travelMode.title)
                .accessibilityHint(showModes ? "Hides travel modes" : "Shows travel modes")

                Button {
                    if session.joystickActive {
                        session.stopJoystick()
                    } else {
                        session.startJoystick(pairing: pairing)
                    }
                } label: {
                    Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(session.joystickActive ? .black : .primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(session.joystickActive ? LocusTheme.accentSecondary : Color.primary.opacity(0.08))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Joystick")
                .accessibilityValue(session.joystickActive ? "On" : "Off")

                Spacer(minLength: 0)

                if session.isSpoofing {
                    Button {
                        session.stop(pairing: pairing)
                    } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(LocusTheme.danger))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        guard let pin = session.pin else {
                            session.lastError = "Tap the map to drop a pin first."
                            return
                        }
                        session.teleport(to: pin, pairing: pairing)
                    } label: {
                        Text("Teleport")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(LocusTheme.accent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isBusy)
                }
            }
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
    }

    private func trayIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
    }
}
