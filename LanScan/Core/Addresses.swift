import Foundation

/// An IPv4 address stored in host byte order.
struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    var raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    init(_ addr: in_addr) { raw = UInt32(bigEndian: addr.s_addr) }

    init?(_ string: String) {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        self.init(addr)
    }

    var inAddr: in_addr { in_addr(s_addr: raw.bigEndian) }

    var octets: [UInt8] {
        [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
    }

    var description: String { octets.map(String.init).joined(separator: ".") }

    /// The `in-addr.arpa` labels used for reverse lookups.
    var reverseLabels: [String] { octets.reversed().map(String.init) + ["in-addr", "arpa"] }

    static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.raw < rhs.raw }

    init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = IPv4(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad IPv4 \(string)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A 48-bit Ethernet hardware address.
struct MACAddress: Hashable, Sendable, CustomStringConvertible, Codable {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    init?(_ string: String) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == "-" })
        let values = parts.compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6, values.count == 6 else { return nil }
        self.bytes = values
    }

    var description: String { bytes.map { String(format: "%02X", $0) }.joined(separator: ":") }

    var value: UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }

    /// Randomised "private Wi-Fi addresses" set the locally-administered bit.
    var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }
    var isMulticast: Bool { bytes[0] & 0x01 != 0 }
    var isBroadcast: Bool { bytes.allSatisfy { $0 == 0xFF } }
    var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = MACAddress(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad MAC \(string)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension MACAddress {
    /// Reads the link-layer address out of a `sockaddr_dl`, whose data can run past the declared struct size.
    init?(sockaddrDL pointer: UnsafeRawPointer) {
        let sdl = pointer.loadUnaligned(as: sockaddr_dl.self)
        guard sdl.sdl_alen == 6 else { return nil }
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)!
        let start = pointer + dataOffset + Int(sdl.sdl_nlen)
        self.init(bytes: (0..<6).map { start.load(fromByteOffset: $0, as: UInt8.self) })
    }
}

/// An IPv6 address. Link-local addresses have the KAME-embedded scope (bytes 2–3) cleared.
struct IPv6: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        var bytes = bytes
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            bytes[2] = 0
            bytes[3] = 0
        }
        self.bytes = bytes
    }

    init(_ addr: in6_addr) {
        let raw = withUnsafeBytes(of: addr) { Array($0) }
        self.init(bytes: raw)!
    }

    init?(_ string: String) {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, string.split(separator: "%").first.map(String.init) ?? string, &addr) == 1 else { return nil }
        self.init(addr)
    }

    var in6Addr: in6_addr {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        return addr
    }

    var isLinkLocal: Bool { bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 }
    var isMulticast: Bool { bytes[0] == 0xFF }
    var prefix64: ArraySlice<UInt8> { bytes[0..<8] }

    var description: String {
        var addr = in6Addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }

    /// Global addresses sort before link-local ones.
    static func < (lhs: IPv6, rhs: IPv6) -> Bool {
        if lhs.isLinkLocal != rhs.isLinkLocal { return !lhs.isLinkLocal }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = IPv6(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad IPv6 \(string)"))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
