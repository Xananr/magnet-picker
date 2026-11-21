import Foundation

/// 从任意文本（纯链接、txt、整页 HTML）里抽出磁力与 ed2k。
enum LinkParser {

    private static let magnetPattern = "magnet:\\?[^\"'<>\\s\\\\)]+"
    private static let ed2kPattern = "ed2k://\\|file\\|[^|]+\\|[^|]+\\|[^|]+\\|/"

    private static let sizeToken = try! NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s?(TB|GB|MB|G|M)\\b",
        options: [.caseInsensitive]
    )

    static func extract(from text: String) -> [ResultItem] {
        let decoded = decodeEntities(text)
        var results: [String: ResultItem] = [:]
        var order: [String] = []

        for raw in matches(of: magnetPattern, in: decoded) {
            guard let item = parseMagnet(raw) else { continue }
            merge(item, into: &results, order: &order)
        }

        for raw in matches(of: ed2kPattern, in: decoded, options: [.caseInsensitive]) {
            guard let item = parseEd2k(raw) else { continue }
            merge(item, into: &results, order: &order)
        }

        return order.compactMap { results[$0] }
    }

    static func merge(_ item: ResultItem, into results: inout [String: ResultItem], order: inout [String]) {
        if var existing = results[item.id] {
            for tracker in item.trackers where !existing.trackers.contains(tracker) {
                existing.trackers.append(tracker)
            }
            if item.name.count > existing.name.count { existing.name = item.name }
            if item.size > existing.size { existing.size = item.size }
            if existing.magnet.isEmpty { existing.magnet = item.magnet }
            results[item.id] = existing
        } else {
            results[item.id] = item
            order.append(item.id)
        }
    }

    // MARK: 磁力

    static func parseMagnet(_ raw: String) -> ResultItem? {
        guard let queryStart = raw.firstIndex(of: "?") else { return nil }
        let query = String(raw[raw.index(after: queryStart)...])
        var hash = ""
        var displayName = ""
        var trackers: [String] = []
        var size: Int64 = 0

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            switch key {
            case "xt":
                var token = value.lowercased()
                if token.hasPrefix("urn:btih:") { token.removeFirst("urn:btih:".count) }
                if token.count == 40 {
                    hash = token
                } else if token.count == 32, let decoded = base32ToHex(token) {
                    hash = decoded
                }
            case "dn":
                displayName = value
            case "tr":
                if !value.isEmpty { trackers.append(value) }
            case "xl":
                if let parsed = Int64(value) { size = parsed }
            default:
                break
            }
        }

        guard hash.count == 40 else { return nil }
        var item = ResultItem(
            id: "magnet:" + hash,
            kind: .magnet,
            name: displayName.isEmpty ? hash : displayName,
            infoHash: hash
        )
        item.trackers = trackers
        item.size = size
        item.magnet = magnetURI(hash: hash, name: item.name, trackers: trackers, size: size)
        return item
    }

    static func magnetURI(hash: String, name: String, trackers: [String], size: Int64) -> String {
        var parts = ["magnet:?xt=urn:btih:" + hash]
        if !name.isEmpty, let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
            parts.append("dn=" + encoded)
        }
        if size > 0 { parts.append("xl=\(size)") }
        for tracker in trackers {
            if let encoded = tracker.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
                parts.append("tr=" + encoded)
            }
        }
        return parts.joined(separator: "&")
    }

    // MARK: ed2k

    static func parseEd2k(_ raw: String) -> ResultItem? {
        let body = raw.replacingOccurrences(of: "ed2k://|file|", with: "")
            .replacingOccurrences(of: "|/", with: "")
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let size = Int64(parts[1]) ?? 0
        let hash = String(parts[2]).lowercased()
        guard hash.count == 32 else { return nil }
        var item = ResultItem(
            id: "ed2k:" + hash,
            kind: .ed2k,
            name: name,
            infoHash: hash
        )
        item.size = size
        item.ed2k = raw
        item.note = "eD2K 源数未知"
        return item
    }

    // MARK: 网页里的体积

    /// 网页锚文本常写成「4K 15.29GB 文件名」，磁力本身又缺 xl，这里补上体积。
    static func enrichSizes(html: String, items: inout [ResultItem]) {
        let decoded = decodeEntities(html)
        let ns = decoded as NSString
        for raw in matches(of: magnetPattern, in: decoded) {
            guard let item = parseMagnet(raw), item.size == 0 else { continue }
            guard let index = items.firstIndex(where: { $0.id == item.id && $0.size == 0 }) else { continue }
            let linkRange = ns.range(of: raw)
            guard linkRange.location != NSNotFound else { continue }
            let start = max(0, linkRange.location - 280)
            let window = NSRange(location: start, length: min(340, ns.length - start))
            let context = ns.substring(with: window)
            if let size = lastSize(in: context) {
                items[index].size = size
            }
        }
    }

    static func lastSize(in text: String) -> Int64? {
        let ns = text as NSString
        let results = sizeToken.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard let last = results.last else { return nil }
        let token = ns.substring(with: last.range)
        return Format.parseSize(token)
    }

    // MARK: 工具

    static func matches(of pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let map = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#x27;": "'"
        ]
        for (key, value) in map {
            result = result.replacingOccurrences(of: key, with: value, options: [.caseInsensitive])
        }
        return result
    }

    static func base32ToHex(_ input: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var output = ""
        for ch in input.uppercased() {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                let byte = UInt8((value >> bits) & 0xFF)
                output += String(format: "%02x", byte)
            }
        }
        return output.count >= 40 ? String(output.prefix(40)) : output
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+")
        return set
    }()
}
