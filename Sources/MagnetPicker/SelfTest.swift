import Foundation

/// 无 UI 自检入口：`MagnetPicker --selftest`
enum SelfTest {

    static func run() {
        print("=== MagnetPicker selftest ===")
        parseTest()
        scoreTest()
        magnetRebuildTest()
        ariaRequestTest()
        sizeTest()
        pageTest()
        probeTest()
        print("=== done ===")
    }

    private static let magnetA = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big.Buck.Bunny.2008.1080p.BluRay.x264&tr=udp://tracker.opentrackr.org:1337/announce&tr=http://tracker.openbittorrent.com:80/announce"
    private static let ed2kA = "ed2k://|file|Some.Movie.2001.720p.mkv|734003200|A1B2C3D4E5F60718293A4B5C6D7E8F90|/"

    private static func parseTest() {
        let items = LinkParser.extract(from: magnetA + "\n" + ed2kA)
        assert(items.count == 2, "解析数量")
        let magnet = items.first { $0.kind == .magnet }
        assert(magnet?.infoHash == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c", "磁力 hash")
        assert(magnet?.trackers.count == 2, "tracker 数量")
        let ed2k = items.first { $0.kind == .ed2k }
        assert(ed2k?.size == 734_003_200, "ed2k 体积")
        print("[解析] 2 条（1 磁力 + 1 ed2k）✓")

        // 同一个种子带两个 tracker，应合并成一条
        let merged = LinkParser.extract(from: magnetA.replacingOccurrences(of: "&tr=http://tracker.openbittorrent.com:80/announce", with: "")
                                        + "\nmagnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Bunny&tr=http://tracker.openbittorrent.com:80/announce")
        assert(merged.count == 1, "合并数量")
        assert(merged.first?.trackers.count == 2, "合并 tracker")
        print("[合并] 同 hash 两个 tracker → 1 条 ✓")
    }

    private static func scoreTest() {
        let remux = ReleaseParsing.score(name: "Movie.2022.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-FGT",
                                         size: 56_500_000_000).0
        let webrip = ReleaseParsing.score(name: "Movie.2022.1080p.WEBRip.DDP5.1.Atmos.x264-NOGRP",
                                          size: 9_300_000_000).0
        let cam = ReleaseParsing.score(name: "Movie.2022.1080p.HDCAM.x264", size: 2_000_000_000).0
        assert(remux > 80, "REMUX 应高分")
        assert(webrip > 45 && webrip < 75, "WEBRip 中等分")
        assert(cam < 25, "枪版应低分")

        let camMany = ReleaseParsing.total(availability: 100, quality: cam, isCam: true, weight: 0.6)
        let normal = ReleaseParsing.total(availability: 55.8, quality: 70, isCam: false, weight: 0.6)
        assert(camMany < normal, "枪版做种再多也不该超过正常片源")
        let remuxText = String(format: "%.1f", remux)
        let webripText = String(format: "%.1f", webrip)
        let camText = String(format: "%.1f", cam)
        print("[评分] REMUX \(remuxText) / WEBRip \(webripText) / 枪版 \(camText) ✓")
    }

    private static func magnetRebuildTest() {
        let item = LinkParser.parseMagnet(magnetA)
        guard let item else {
            print("[重建] ✗ 解析失败")
            return
        }
        let rebuilt = LinkParser.magnetURI(hash: item.infoHash, name: item.name, trackers: item.trackers, size: item.size)
        let again = LinkParser.parseMagnet(rebuilt)
        assert(again?.infoHash == item.infoHash, "重建 hash")
        assert(again?.trackers.count == 2, "重建 tracker")
        assert(rebuilt.contains("dn="), "重建 dn")
        print("[重建] 带全部 tracker 的磁力可被再次解析 ✓")
    }

    private static func ariaRequestTest() {
        let config = AriaConfig(rpcURL: "http://127.0.0.1:6800/jsonrpc", secret: "abc", savePath: "/tmp/dl")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "aria2.addUri",
            "params": ["token:abc", [magnetA], ["dir": config.savePath, "pause": "false"]]
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else {
            print("[Aria] ✗ 请求体不合法")
            return
        }
        assert(text.contains("aria2.addUri"), "method 名")
        assert(text.contains("token:abc"), "密钥前缀")
        print("[Aria] JSON-RPC 请求体可序列化 ✓")
    }

    private static func sizeTest() {
        assert(Format.parseSize("15.29GB") == 15_290_000_000, "解析 GB")
        assert(Format.parseSize("9.3 GB") == 9_300_000_000, "解析带空格 GB")
        assert(Format.parseSize("700MB") == 700_000_000, "解析 MB")
        print("[体积] 15.29GB / 9.3 GB / 700MB ✓")
    }

    private static func pageTest() {
        let html = """
        <a href="magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&amp;dn=Big.Buck.Bunny">4K 15.29GB<strong>Big.Buck.Bunny.mkv</strong></a>
        """
        var items = LinkParser.extract(from: html)
        LinkParser.enrichSizes(html: html, items: &items)
        assert(items.count == 1, "网页链接数量")
        assert(items.first?.size == 15_290_000_000, "网页体积")
        print("[网页] HTML 实体还原 + 锚文本体积 ✓")
    }

    private static func probeTest() {
        let item = ResultItem(id: "magnet:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
                              kind: .magnet,
                              name: "Big.Buck.Bunny.2008.1080p.BluRay.x264",
                              infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        var item2 = item
        item2.trackers = ["udp://tracker.opentrackr.org:1337/announce",
                          "udp://tracker.openbittorrent.com:6969/announce",
                          "http://tracker.trackerfix.com:80/announce"]

        let started = Date()
        let result = runProbe(item2)
        print("[探测] 做种 \(result.seedersText) 可用性 \(result.availability.map { String(format: "%.0f", $0) } ?? "nil") 综合 \(Format.score(result.score))    耗时 \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        assert(result.probed, "应标记已探测")
        print("   tracker 结果：\(result.trackerHits.map { "\($0.shortTracker)=\($0.seeders.map(String.init) ?? ($0.message ?? "?"))" }.joined(separator: ", "))")
        assert(result.trackerHits.count >= 3, "至少 3 个 tracker 有结果（默认会补公共 tracker）")
    }

    /// 用信号量把异步探测转成同步，方便 "--selftest" 直接打印
    private static func runProbe(_ item: ResultItem) -> ResultItem {
        var output = item
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            output = await ProbeEngine.probe(item, settings: ProbeSettings())
            semaphore.signal()
        }
        semaphore.wait()
        return output
    }

    private static func assert(_ condition: Bool, _ label: String) {
        if !condition {
            print("  ✗ \(label) 断言失败")
        }
    }
}
