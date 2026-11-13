import Foundation
import Synchronization

/// Maps MAC prefixes (MA-L /24, MA-M /28, MA-S /36) to manufacturer names using Wireshark's `manuf` file,
/// downloaded once and cached in Application Support.
final class VendorDatabase: Sendable {
    static let shared = VendorDatabase()

    private static let source = URL(string: "https://www.wireshark.org/download/automated/data/manuf")!
    private static let maxAge: TimeInterval = 30 * 24 * 3600

    private struct State {
        var prefixes: [Int: [UInt64: String]] = [:]
        var updated: Date?
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.prefixes.values.reduce(0) { $0 + $1.count } } }
    var lastUpdated: Date? { state.withLock { $0.updated } }
    var isLoaded: Bool { count > 0 }

    static var cacheURL: URL {
        URL.applicationSupportDirectory.appending(components: "LanScan", "manuf.txt")
    }

    func vendor(for mac: MACAddress) -> String? {
        let value = mac.value
        return state.withLock { state in
            for bits in [36, 28, 24] {
                if let name = state.prefixes[bits]?[value >> UInt64(48 - bits)] { return name }
            }
            return nil
        }
    }

    /// Loads the cached file, downloading a fresh copy when missing, stale or `force`d.
    func load(force: Bool = false) async throws {
        let url = Self.cacheURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date

        if !force, let modified, !isLoaded {
            try await parse(url, updated: modified)
        }
        let stale = modified.map { Date.now.timeIntervalSince($0) > Self.maxAge } ?? true
        guard force || stale else { return }

        let (download, response) = try await URLSession.shared.download(from: Self.source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: download, to: url)
        try await parse(url, updated: .now)
    }

    private func parse(_ url: URL, updated: Date) async throws {
        let parsed = try await Task.detached(priority: .utility) {
            try Self.parse(String(contentsOf: url, encoding: .utf8))
        }.value
        guard !parsed.isEmpty else { return }
        state.withLock { $0 = State(prefixes: parsed, updated: updated) }
    }

    /// Lines look like `00:00:0C<TAB>Cisco<TAB>Cisco Systems, Inc` or `00:1B:C5:00:00:00/36<TAB>…`.
    private static func parse(_ text: String) -> [Int: [UInt64: String]] {
        var prefixes: [Int: [UInt64: String]] = [24: [:], 28: [:], 36: [:]]
        text.enumerateLines { line, _ in
            guard let first = line.first, first != "#" else { return }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { return }
            let spec = fields[0].split(separator: "/")
            let hex = spec[0].filter(\.isHexDigit)
            let bits = spec.count > 1 ? Int(spec[1]) ?? 24 : hex.count * 4
            guard [24, 28, 36].contains(bits), hex.count * 4 >= bits,
                  let value = UInt64(hex.prefix(bits / 4), radix: 16) else { return }
            let name = String(fields.count >= 3 ? fields[2] : fields[1]).trimmingCharacters(in: .whitespaces)
            prefixes[bits]?[value] = name
        }
        return prefixes
    }
}
