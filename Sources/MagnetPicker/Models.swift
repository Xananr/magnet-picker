import Foundation

// MARK: - 链接类型

enum LinkKind: String, Codable {
    case magnet
    case ed2k
}

// MARK: - 单个 tracker 的探测结果

struct TrackerHit: Identifiable, Hashable {
    var id = UUID()
    var tracker: String
    var seeders: Int?
    var leechers: Int?
    var message: String?
    var cached = false

    var ok: Bool { seeders != nil }

    /// 只保留 host:port，窄栏里才不会挤成一团。
    var shortTracker: String {
        var text = tracker
        for prefix in ["udp://", "http://", "https://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        return text
    }
}

// MARK: - 结果条目

struct ResultItem: Identifiable, Hashable {
    var id: String              // "magnet:<infoHash>" / "ed2k:<hash>"
    var kind: LinkKind
    var name: String
    var infoHash: String        // 40 位十六进制，或 ed2k 的 32 位十六进制
    var trackers: [String] = []
    var magnet: String = ""
    var ed2k: String?
    var size: Int64 = 0

    // 探测
    var dhtPeers: Int = 0
    var seeders: Int?
    var leechers: Int?
    var probed = false
    var trackerOK = 0
    var trackerFail = 0
    var trackerHits: [TrackerHit] = []

    // 评分
    var availability: Double?
    var quality: Double = 0
    var score: Double = 0
    var qualityDetail: [String: String] = [:]
    var note: String?
    var group: String = ""

    var shortVersion: String { ReleaseParsing.shortVersion(name) }
    var movieLabel: String { ReleaseParsing.movieLabel(name) }
    var resolutionLabel: String { qualityDetail["分辨率"] ?? "—" }
    var sourceLabel: String { qualityDetail["来源"] ?? "—" }
    var audioLabel: String { qualityDetail["音轨"] ?? "—" }
    var sizeText: String { Format.size(size) }

    var isCam: Bool {
        let src = qualityDetail["来源"] ?? ""
        return src == "CAM" || src == "TS/TC"
    }

    var seedersText: String {
        guard let s = seeders else { return "—" }
        return "\(s)"
    }

    /// 发到下载器时优先用带全部 tracker 的磁力
    var downloadURI: String {
        if kind == .magnet { return magnet.isEmpty ? "magnet:?xt=urn:btih:\(infoHash)&dn=\(name)" : magnet }
        return ed2k ?? ""
    }
}

// MARK: - 筛选条件

enum SegmentMode: String, CaseIterable, Identifiable {
    case movie = "按片名"
    case resolution = "按分辨率"
    case flat = "不分段"
    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .movie: return "片名"
        case .resolution: return "分辨率"
        case .flat: return "不分段"
        }
    }
}

enum ResolutionCap: String, CaseIterable, Identifiable {
    case any = "全部"
    case uhd = "4K"
    case fhd = "1080p"
    case hd = "720p"
    var id: String { rawValue }

    var shortLabel: String { rawValue }

    func allows(_ label: String) -> Bool {
        switch self {
        case .any: return true
        case .uhd: return label == "2160p" || label == "4K"
        case .fhd: return label == "1080p"
        case .hd: return label == "720p"
        }
    }
}

struct Filters {
    var search: String = ""
    var resolutionCap: ResolutionCap = .any
    var segment: SegmentMode = .movie
    var excludeCam: Bool = true
    var minSeeders: Int = 0
}

// MARK: - 探测参数

struct ProbeSettings: Codable {
    var trackerTimeout: Double = 5
    var dhtTimeout: Double = 4
    var maxTrackers: Int = 10
    var workers: Int = 16
    var useDHT: Bool = true
    var useDefaultTrackers: Bool = true
    var weightAvailability: Double = 0.6
    var cacheTTL: Double = 6 * 3600
}

// MARK: - 数值与格式

enum Format {
    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index >= 3 {
            return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
        }
        return String(format: "%.0f %@", value, units[index])
    }

    static func score(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func seeders(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)"
    }

    static func parseSize(_ text: String) -> Int64 {
        // "15.29GB" / "9.3 GB" / "700MB"
        let upper = text.uppercased().replacingOccurrences(of: " ", with: "")
        var number = ""
        var unit = ""
        for ch in upper {
            if ch.isNumber || ch == "." { number.append(ch) } else { unit.append(ch) }
        }
        guard let value = Double(number) else { return 0 }
        let factor: Double
        switch unit {
        case "GB", "G": factor = 1_000_000_000
        case "MB", "M": factor = 1_000_000
        case "TB", "T": factor = 1_000_000_000_000
        case "KB", "K": factor = 1_000
        default: factor = 1
        }
        return Int64(value * factor)
    }
}
