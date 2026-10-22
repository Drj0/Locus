import Foundation

enum TunnelConfig {
    /// LocalDevVPN / SideStore-style loopback tunnel endpoint.
    static let defaultIP = "10.7.0.1"
    static let defaultsKey = "locus.targetDeviceIP"

    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey).map(normalized)
        guard let stored, !stored.isEmpty else { return defaultIP }
        return stored
    }

    /// LocalDevVPN shows addresses in CIDR form ("10.7.0.1/32"); keep just the address.
    static func normalized(_ value: String) -> String {
        String(value.prefix { $0 != "/" }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setTargetIP(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}
