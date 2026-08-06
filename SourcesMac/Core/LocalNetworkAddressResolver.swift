import Darwin
import Foundation

struct LocalNetworkInterfaceAddress: Equatable, Sendable {
    let name: String
    let address: String
}

enum LocalNetworkAddressResolver {
    static func preferredIPv4Address() -> String? {
        preferredIPv4Address(from: currentIPv4Addresses())
    }

    static func preferredIPv4Address(from addresses: [LocalNetworkInterfaceAddress]) -> String? {
        let usable = addresses.filter {
            !$0.address.hasPrefix("127.") && !$0.address.hasPrefix("169.254.")
        }
        let priority: (LocalNetworkInterfaceAddress) -> Int = { value in
            switch value.name {
            case "en0": return 0
            case "en1": return 1
            default: return value.name.hasPrefix("en") ? 2 : 3
            }
        }
        return usable.sorted {
            let left = priority($0)
            let right = priority($1)
            return left == right ? $0.name < $1.name : left < right
        }.first?.address
    }

    private static func currentIPv4Addresses() -> [LocalNetworkInterfaceAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [LocalNetworkInterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            result.append(
                LocalNetworkInterfaceAddress(
                    name: String(cString: interface.pointee.ifa_name),
                    address: String(cString: hostname)
                )
            )
        }
        return result
    }
}
