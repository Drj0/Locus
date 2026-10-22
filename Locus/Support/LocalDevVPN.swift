import Darwin
import Foundation
import UIKit

enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// Starts the tunnel, then returns to Locus via `locus://`.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=locus")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// True when traffic to the target Device IP is routed into a VPN tunnel (utun).
    /// Checks the route instead of LocalDevVPN's own interface address: that address is
    /// user-configurable (its default moved from 10.7.0.0 to 10.7.1.1), and other
    /// loopback VPNs (ClashMi / sing-box) use their own subnets.
    static var isConnected: Bool {
        #if DEBUG
        // Simulator preview of the connected UI: launch with `-LocusPreviewVPNConnected YES`.
        if UserDefaults.standard.bool(forKey: "LocusPreviewVPNConnected") { return true }
        #endif
        let target = TunnelConfig.targetIP
        guard let source = routedSourceAddress(to: target), source != target else { return false }
        return ipv4Interfaces().contains { $0.name.hasPrefix("utun") && $0.address == source }
    }

    /// True when `ip` belongs to this iPhone, e.g. LocalDevVPN's Tunnel IP typed in
    /// where its Device IP belongs.
    static func isOwnAddress(_ ip: String) -> Bool {
        let ip = TunnelConfig.normalized(ip)
        return ipv4Interfaces().contains { $0.address == ip }
    }

    static func openInstalled() {
        UIApplication.shared.open(enableURL)
    }

    static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    /// Open LocalDevVPN to connect if installed; otherwise App Store.
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
        }
    }

    /// Local address the kernel would use to reach `ip`. A UDP connect only does the
    /// route lookup; nothing is sent.
    private static func routedSourceAddress(to ip: String) -> String? {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(49152).bigEndian
        guard inet_pton(AF_INET, ip, &destination.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let connected = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }

        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &host, socklen_t(host.count)) != nil else { return nil }
        return String(cString: host)
    }

    private static func ipv4Interfaces() -> [(name: String, address: String)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [(name: String, address: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(
                    addr,
                    nameLen,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    results.append((String(cString: interface.ifa_name), String(cString: host)))
                }
            }
            ptr = interface.ifa_next
        }
        return results
    }
}
