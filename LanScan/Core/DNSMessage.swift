/// Just enough DNS wire format to ask unicast DNS, mDNS and NetBIOS questions and read the answers.
enum DNSType {
    static let a: UInt16 = 1
    static let ptr: UInt16 = 12
    static let txt: UInt16 = 16
    static let srv: UInt16 = 33
    static let nbstat: UInt16 = 33 // NetBIOS reuses SRV's number for NBSTAT.
}

struct DNSRecord: Sendable {
    enum Data: Sendable {
        case ptr([String])
        case txt([String])
        case srv(port: UInt16, target: [String])
        case a(IPv4)
        case other
    }

    let name: [String]
    let type: UInt16
    let data: Data
}

struct DNSMessage: Sendable {
    let id: UInt16
    let records: [DNSRecord]

    static func query(id: UInt16, name: [String], type: UInt16, recursionDesired: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(u16: id)
        bytes.append(u16: recursionDesired ? 0x0100 : 0)
        bytes.append(u16: 1)
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0])
        for label in name {
            let utf8 = Array(label.utf8.prefix(63))
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        bytes.append(u16: type)
        bytes.append(u16: 1)
        return bytes
    }

    init?(_ bytes: [UInt8]) {
        var reader = DNSReader(bytes: bytes)
        guard let id = reader.u16(), let flags = reader.u16(), flags & 0x8000 != 0,
              let questions = reader.u16(), let answers = reader.u16(),
              let authority = reader.u16(), let additional = reader.u16() else { return nil }
        self.id = id

        for _ in 0..<questions {
            guard reader.name() != nil, reader.u16() != nil, reader.u16() != nil else { return nil }
        }

        var records: [DNSRecord] = []
        for _ in 0..<(Int(answers) + Int(authority) + Int(additional)) {
            guard let name = reader.name(), let type = reader.u16(), reader.u16() != nil,
                  reader.u32() != nil, let length = reader.u16() else { break }
            let end = reader.offset + Int(length)
            guard end <= bytes.count else { break }

            var data = DNSRecord.Data.other
            switch type {
            case DNSType.ptr:
                if let target = reader.name() { data = .ptr(target) }
            case DNSType.txt:
                var strings: [String] = []
                while reader.offset < end, let count = reader.u8(), reader.offset + Int(count) <= end {
                    strings.append(String(decoding: bytes[reader.offset ..< reader.offset + Int(count)], as: UTF8.self))
                    reader.offset += Int(count)
                }
                data = .txt(strings)
            case DNSType.srv:
                if reader.u16() != nil, reader.u16() != nil, let port = reader.u16(), let target = reader.name() {
                    data = .srv(port: port, target: target)
                }
            case DNSType.a where length == 4:
                if let raw = reader.u32() { data = .a(IPv4(raw: raw)) }
            default:
                break
            }
            reader.offset = end
            records.append(DNSRecord(name: name, type: type, data: data))
        }
        self.records = records
    }
}

struct DNSReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() -> UInt32? {
        guard let high = u16(), let low = u16() else { return nil }
        return UInt32(high) << 16 | UInt32(low)
    }

    /// Reads a possibly-compressed domain name as raw labels (labels may themselves contain dots).
    mutating func name() -> [String]? {
        var labels: [String] = []
        var position = offset
        var jumped = false
        var hops = 0
        while true {
            guard position < bytes.count else { return nil }
            let length = Int(bytes[position])
            if length == 0 {
                position += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard position + 1 < bytes.count, hops < 32 else { return nil }
                if !jumped { offset = position + 2 }
                jumped = true
                hops += 1
                position = (length & 0x3F) << 8 | Int(bytes[position + 1])
                continue
            }
            guard position + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[position + 1 ..< position + 1 + length], as: UTF8.self))
            position += 1 + length
        }
        if !jumped { offset = position }
        return labels
    }
}

extension [UInt8] {
    mutating func append(u16 value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}

extension [String] {
    /// Joins labels into a presentable host name, dropping the root.
    var hostName: String { joined(separator: ".") }
}
