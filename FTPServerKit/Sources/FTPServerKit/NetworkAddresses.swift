import Foundation
import Network

public struct NetworkInterfaceAddress: Sendable, Hashable {
    public let interface: String
    public let address: String
    public let isIPv6: Bool

    public var displayName: String {
        switch interface {
        case "en0": return "Wi-Fi"
        case let name where name.hasPrefix("bridge"): return "Personal Hotspot"
        case let name where name.hasPrefix("en"): return "Ethernet"
        case let name where name.hasPrefix("utun") || name.hasPrefix("ipsec"): return "VPN"
        default: return interface
        }
    }
}

public enum NetworkAddresses {
    public static func localAddresses(includeIPv6: Bool = false) -> [NetworkInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [NetworkInterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let sa = ifa.ifa_addr,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || (includeIPv6 && family == AF_INET6) else { continue }
            let name = String(validatingCString: ifa.ifa_name) ?? ""
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET6 && address.lowercased().hasPrefix("fe80") { continue }
            results.append(NetworkInterfaceAddress(interface: name, address: address, isIPv6: family == AF_INET6))
        }
        func rank(_ a: NetworkInterfaceAddress) -> Int {
            (a.interface == "en0" ? 0 : a.interface.hasPrefix("bridge") ? 1 : 2) + (a.isIPv6 ? 10 : 0)
        }
        return results.sorted { (rank($0), $0.interface) < (rank($1), $1.interface) }
    }
}

extension NWEndpoint.Host {
    /// Raw address bytes with IPv4-mapped IPv6 collapsed to IPv4, so the same peer compares
    /// equal regardless of which socket family reported it.
    var normalizedAddress: Data? {
        switch self {
        case .ipv4(let address): return address.rawValue
        case .ipv6(let address): return address.asIPv4?.rawValue ?? address.rawValue
        default: return nil
        }
    }

    var ipv4Address: IPv4Address? {
        switch self {
        case .ipv4(let address): return address
        case .ipv6(let address): return address.asIPv4
        default: return nil
        }
    }

    var displayString: String {
        switch self {
        case .ipv4(let address): return "\(IPv4Address(address.rawValue)!)"
        case .ipv6(let address):
            if let v4 = address.asIPv4 { return "\(v4)" }
            return "\(IPv6Address(address.rawValue)!)"
        case .name(let name, _): return name
        @unknown default: return "\(self)"
        }
    }
}

extension NWEndpoint {
    var host: NWEndpoint.Host? {
        if case .hostPort(let host, _) = self { return host }
        return nil
    }
}
