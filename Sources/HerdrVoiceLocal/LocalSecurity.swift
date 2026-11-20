import CryptoKit
import Foundation

/// Checks for the helper's loopback WebSocket and the app's tool handshake.
public enum LocalSecurity {
    /// Only the app may connect: a loopback peer, a loopback Host, no browser Origin, and the session's bearer token.
    public static func authorizeUpgrade(headers: [(name: String, value: String)], remoteAddress: String?,
                                        token: String) -> Bool {
        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var remote = remoteAddress ?? ""
        if remote.hasPrefix("::ffff:") { remote.removeFirst("::ffff:".count) }
        guard remote == "127.0.0.1" || remote == "::1" else { return false }
        guard header("Origin") == nil else { return false }
        var host = header("Host") ?? ""
        if host.hasPrefix("[") { host = String(host.dropFirst().prefix { $0 != "]" }) }
        else { host = String(host.prefix { $0 != ":" }) }
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
        return constantTimeEqual(Data((header("Authorization") ?? "").utf8), Data("Bearer \(token)".utf8))
    }

    /// The tool list the app sent matches the manifest it signed off on: same count, same order, same digest. The
    /// digest is computed exactly as `HerdrTools.toolManifest` does, over the sorted-key JSON of the schemas.
    public static func validateManifest(_ manifest: JSONValue, tools: JSONValue) -> Bool {
        guard let list = tools.array, let names = manifest["names"]?.array,
              manifest["count"]?.safeInteger == list.count, names.count == list.count,
              zip(names, list).allSatisfy({ $0.string != nil && $0.string == $1["name"]?.string }),
              let digest = manifest["digest"]?.string, let expected = hexBytes(digest),
              let data = try? JSONSerialization.data(withJSONObject: tools.any, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return constantTimeEqual(Data(SHA256.hash(data: data)), expected)
    }

    static func hexBytes(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
