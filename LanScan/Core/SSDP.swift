import Foundation
import Synchronization

/// UPnP discovery: an SSDP M-SEARCH to the multicast group, then each responder's device
/// description XML for its friendly name and model. TVs, consoles, media servers, NAS boxes,
/// routers and many appliances answer this regardless of who made the router.
enum SSDP {
    struct Description: Sendable {
        var friendlyName: String?
        var model: String?
    }

    private static let group = IPv4(raw: 0xEFFF_FFFA) // 239.255.255.250

    static func discover(on interface: IPv4, cancel: CancelToken) -> [IPv4: Description] {
        guard let socket = DatagramSocket() else { return [:] }
        var outgoing = interface.inAddr
        setsockopt(socket.fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))

        let search = Array("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: ssdp:all\r
        \r

        """.utf8)

        var locations: [IPv4: URL] = [:]
        func handle(_ from: IPv4, _ bytes: [UInt8]) {
            guard let location = header("location", in: bytes), let url = URL(string: location),
                  url.host() == from.description else { return }
            // Prefer the root device description over per-service documents.
            if locations[from] == nil || location.localizedCaseInsensitiveContains("desc") {
                locations[from] = url
            }
        }

        for _ in 0..<2 {
            socket.send(search, to: group, port: 1900)
            socket.collect(until: monotonicNanos() + 1_300_000_000, cancel: cancel, handler: handle)
        }
        locations[interface] = nil
        guard !cancel.isCancelled, !locations.isEmpty else { return [:] }

        let results = Mutex<[IPv4: Description]>([:])
        let entries = Array(locations)
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            let (ip, url) = entries[index]
            if let description = fetch(url) { results.withLock { $0[ip] = description } }
        }
        return results.withLock { $0 }
    }

    private static func header(_ name: String, in bytes: [UInt8]) -> String? {
        String(decoding: bytes, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix(name + ":") }
            .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
    }

    private static func fetch(_ url: URL) -> Description? {
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("LanScan/1.0 UPnP/1.1", forHTTPHeaderField: "User-Agent")
        let body = Mutex<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body.withLock { $0 = data }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 3) == .success,
              let data = body.withLock({ $0 }) else { return nil }

        let xml = String(decoding: data.prefix(64_000), as: UTF8.self)
        let description = Description(friendlyName: element("friendlyName", in: xml),
                                      model: element("modelName", in: xml))
        return description.friendlyName == nil && description.model == nil ? nil : description
    }

    /// First `<tag>value</tag>` in the document, with basic XML entities decoded.
    private static func element(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound ..< xml.endIndex) else { return nil }
        let value = xml[open.upperBound ..< close.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
