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
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var scenePhase
    @Binding var expanded: Bool

    @State private var tunnelConnected = LocalDevVPN.isConnected
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled

    private var color: Color {
        switch session.status {
        case .idle: return tunnelConnected ? LocusTheme.statusGood : LocusTheme.statusWarn
        case .active: return LocusTheme.statusGood
        case .connecting, .reconnecting: return LocusTheme.statusWarn
        case .dropped: return LocusTheme.statusBad
        }
    }

    private var title: String {
        switch session.status {
        case .idle: return tunnelConnected ? "VPN Connected" : "Connect LocalDevVPN"
        case .connecting: return "Connecting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Disconnected"
        }
    }

    private var locationText: String {
        switch session.status {
        case .idle: return "Real location"
        case .connecting: return "Connecting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Dropped"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                pill
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Status: \(title)")
            .accessibilityHint(expanded ? "Hides connection details" : "Shows connection details")

            if expanded {
                details
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshTunnel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTunnel() }
        }
        .onChange(of: session.status) { _, _ in
            refreshTunnel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            // LocalDevVPN connection changes show up here even though we don’t own the VPN.
            refreshTunnel()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshTunnel()
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if session.status != .idle {
                // Spoof state leads; keep the tunnel readable at a glance too.
                Image(systemName: tunnelConnected ? "lock.shield.fill" : "lock.open.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tunnelConnected ? LocusTheme.accent : LocusTheme.statusWarn)
                    .accessibilityHidden(true)
            }

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow("LocalDevVPN", value: tunnelConnected ? "Connected" : "Not connected",
                      tint: tunnelConnected ? LocusTheme.statusGood : LocusTheme.statusWarn)
            detailRow("Device IP", value: TunnelConfig.targetIP, monospaced: true)
            detailRow("Location", value: locationText, tint: session.status == .idle ? nil : color)
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

            if !tunnelConnected || session.status.isDropped {
                Button {
                    LocalDevVPN.openOrInstall()
                } label: {
                    Label(localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN",
                          systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(LocusTheme.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
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
        if !tunnelConnected {
            return "Connect LocalDevVPN, then come back. Locus uses its Device IP (default \(TunnelConfig.defaultIP)), not the Tunnel IP — change it in Settings."
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

    private func refreshTunnel() {
        tunnelConnected = LocalDevVPN.isConnected
        localDevVPNInstalled = LocalDevVPN.isInstalled
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

                // Current travel mode; tap to choose another.
                Button {
                    withAnimation(.snappy) { showModes.toggle() }
                } label: {
                    Image(systemName: session.travelMode.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(showModes ? .black : LocusTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(showModes ? LocusTheme.accent : Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Travel mode")
                .accessibilityValue(session.travelMode.title)

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
