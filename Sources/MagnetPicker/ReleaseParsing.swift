import Foundation

/// 从文件名里读片源信息，并给出质量分。
enum ReleaseParsing {

    static let resolutionTokens = ["2160P", "1080P", "720P", "480P", "4K", "UHD", "8K"]

    // MARK: 分辨率 / 来源 / 编码 / 音轨

    static func resolution(_ name: String) -> String? {
        let upper = name.uppercased()
        if upper.contains("2160P") || upper.contains("4K") || upper.hasPrefix("UHD") { return "2160p" }
        if upper.contains("1080P") || upper.contains("FHD") { return "1080p" }
        if upper.contains("720P") { return "720p" }
        if upper.contains("480P") { return "480p" }
        if upper.contains("8K") { return "4320p" }
        return nil
    }

    static func source(_ name: String) -> String? {
        let upper = name.uppercased()
        if upper.contains("REMUX") { return "REMUX" }
        if upper.contains("BLURAY") || upper.contains("BLU-RAY") || upper.contains("BDRIP") { return "BluRay" }
        if upper.contains("WEB-DL") || upper.contains("WEBDL") { return "WEB-DL" }
        if upper.contains("WEBRIP") || upper.contains("WEB-RIP") { return "WEBRip" }
        if upper.contains("HDRIP") || upper.contains("HDTV") { return "HDRip" }
        if upper.contains("HDTS") || upper.contains("TS/TC") { return "TS/TC" }
        if upper.contains("HDCAM") || upper.contains("CAMRIP") || upper.contains(" CAM ") || upper == "CAM" { return "CAM" }
        if upper.contains("TC") && upper.contains("HD") { return "TS/TC" }
        return nil
    }

    static func codec(_ name: String) -> String? {
        let upper = name.uppercased()
            .replacingOccurrences(of: "H.265", with: "H265")
            .replacingOccurrences(of: "H.264", with: "H264")
        if upper.contains("X265") || upper.contains("H265") || upper.contains("HEVC") { return "x265" }
        if upper.contains("X264") || upper.contains("H264") || upper.contains("AVC") { return "x264" }
        if upper.contains("AV1") { return "AV1" }
        return nil
    }

    static func audio(_ name: String) -> String? {
        let upper = name.uppercased()
        if upper.contains("ATMOS") { return "Atmos" }
        if upper.contains("TRUEHD") { return "TrueHD" }
        if upper.contains("DTS-HD") || upper.contains("DTSHD") { return "DTS-HD" }
        if upper.contains("DTS") { return "DTS" }
        if upper.contains("AC3") || upper.contains("DD5.1") || upper.contains("DDP5.1") || upper.contains("EAC3") { return "AC3" }
        if upper.contains("AAC") { return "AAC" }
        return nil
    }

    static func isHDR(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("HDR") || upper.contains("DOLBY.VISION") || upper.contains("DOVI")
    }

    static func is3D(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("3D") || upper.contains("HALF-SBS") || upper.contains("HSBS")
    }

    static func isCollection(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("COMPLETE") || upper.contains("SEASON") || upper.contains("S01")
            || upper.contains("合集") || upper.contains("全集")
    }

    // MARK: 质量分

    /// 返回（质量分 0~100，明细字典）
    static func score(name: String, size: Int64) -> (Double, [String: String]) {
        var detail: [String: String] = [:]
        var value = 40.0

        if let res = resolution(name) {
            detail["分辨率"] = res
            switch res {
            case "4320p": value += 8
            case "2160p": value += 6
            case "1080p": value += 3
            case "720p": value += 0
            default: value -= 8
            }
        } else {
            value -= 4
        }

        if let src = source(name) {
            detail["来源"] = src
            switch src {
            case "REMUX": value += 42
            case "BluRay": value += 34
            case "WEB-DL": value += 28
            case "WEBRip": value += 18
            case "HDRip": value += 6
            case "TS/TC": value -= 14
            case "CAM": value -= 30
            default: break
            }
        } else {
            value -= 3
        }

        if let c = codec(name) {
            detail["编码"] = c
            switch c {
            case "x265", "AV1": value += 4
            default: value += 1
            }
        }
        if let a = audio(name) {
            detail["音轨"] = a
            switch a {
            case "Atmos": value += 4
            case "TrueHD", "DTS-HD": value += 3
            case "AC3": value += 1
            default: value -= 1
            }
        }
        if isHDR(name) { detail["HDR"] = "是"; value += 3 }
        if name.uppercased().contains("10BIT") || name.uppercased().contains("10-BIT") { value += 1 }

        // 体积是否与该分辨率的常见区间相符
        if size > 0 {
            let res = detail["分辨率"] ?? ""
            let range: ClosedRange<Double>
            switch res {
            case "2160p": range = 4...90
            case "1080p": range = 1.2...30
            case "720p": range = 0.5...10
            default: range = 0.3...12
            }
            let gb = Double(size) / 1_000_000_000
            if gb < range.lowerBound { value -= 9; detail["体积异常"] = "偏小" }
            if gb > range.upperBound { value -= 6; detail["体积异常"] = "偏大" }
        }

        if isCollection(name) { value -= 4 }
        if is3D(name) { value -= 8; detail["3D"] = "是" }

        var clamped = min(100, max(0, value))
        if detail["来源"] == "CAM" || detail["来源"] == "TS/TC" {
            clamped *= 0.35
            if clamped > 22 { clamped = 22 }
        }
        return (clamped, detail)
    }

    // MARK: 可用性

    static func availability(seeders: Int?, dhtPeers: Int, kind: LinkKind) -> Double? {
        if kind == .ed2k { return nil }
        let best = max(seeders ?? 0, dhtPeers)
        guard best > 0 else { return seeders == 0 ? 0 : nil }
        let normalized = min(1.0, log10(1.0 + Double(best)) / log10(51.0))
        return normalized * 100
    }

    static func total(availability: Double?, quality: Double, isCam: Bool, weight: Double) -> Double {
        let a = availability ?? 0
        let result = a * weight + quality * (1 - weight)
        return isCam ? result * 0.35 : result
    }

    // MARK: 名称切分

    static func shortVersion(_ name: String) -> String {
        let stripped = stripExtension(name)
        guard let range = firstResolutionRange(in: stripped) else {
            return stripped.count > 96 ? String(stripped.prefix(96)) : stripped
        }
        var tail = String(stripped[range.lowerBound...])
        tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return tail
    }

    static func movieLabel(_ name: String) -> String {
        let stripped = stripExtension(name)
        var head = stripped
        if let range = firstResolutionRange(in: stripped) {
            head = String(stripped[..<range.lowerBound])
        }
        head = head.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: " -.")
        )
        if head.isEmpty { return "未命名" }
        return head
    }

    static func groupKey(_ name: String, kind: LinkKind, hash: String) -> String {
        if kind == .ed2k { return "ed2k|" + hash }
        return movieLabel(name) + "|" + (resolution(name) ?? "?")
    }

    private static func stripExtension(_ name: String) -> String {
        for ext in [".mkv", ".mp4", ".avi", ".ts", ".rmvb", ".mov"] {
            if name.lowercased().hasSuffix(ext) {
                return String(name.dropLast(ext.count))
            }
        }
        return name
    }

    private static func firstResolutionRange(in text: String) -> Range<String.Index>? {
        let upper = text.uppercased()
        var best: Range<String.Index>?
        for token in resolutionTokens {
            if let range = upper.range(of: token, options: [.literal]) {
                if let current = best {
                    if range.lowerBound < current.lowerBound { best = range }
                } else {
                    best = range
                }
            }
        }
        // 只认前面 3/4 处出现的分辨率标记，避免把片名里的数字误判
        if let best, upper.distance(from: upper.startIndex, to: best.lowerBound) > upper.count * 3 / 4 {
            return nil
        }
        return best
    }
}
