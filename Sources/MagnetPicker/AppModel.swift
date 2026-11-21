import Foundation
import AppKit
import UniformTypeIdentifiers

enum CopyScope {
    case all
    case top(Int)
    case selectedOnly
}

enum AriaScope {
    case selected
    case top(Int)
    case all
}

@MainActor
final class AppModel: ObservableObject {

    // 输入
    @Published var rawInput: String = "" { didSet { scheduleParse() } }
    @Published var pageAddress: String = ""

    // 数据
    @Published var items: [ResultItem] = []
    @Published var filters = Filters()
    @Published var settings = ProbeSettings() { didSet { persistSettings() } }

    // 选择与面板
    @Published var selectedID: String?
    @Published var showInspector = true
    @Published var showSettings = false
    @Published var showAriaSettings = false

    // 进度
    @Published var isProbing = false
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var elapsed: TimeInterval = 0
    @Published var statusLine = "粘链接或填网址，然后点「开始探测」"
    @Published var isFetchingPage = false

    // Aria2
    @Published var ariaConfig = AriaConfig() { didSet { persistAria() } }
    @Published var ariaVersion: String?
    @Published var ariaMessage: String = "未连接"
    @Published var ariaBusy = false

    private var parseTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init() {
        loadPersisted()
        if let url = LaunchConfig.ariaURL {
            ariaConfig.rpcURL = url
            if let secret = LaunchConfig.ariaSecret { ariaConfig.secret = secret }
            persistAria()
        }
        if let file = LaunchConfig.pendingFile {
            loadFile(URL(fileURLWithPath: file))
        } else if let address = LaunchConfig.pendingURL, let url = URL(string: address) {
            pageAddress = address
            Task { await self.fetchPage(url: url) }
        }
        Task { await self.checkAria() }
        if LaunchConfig.autoProbe {
            Task { @MainActor in
                for _ in 0..<60 where self.items.isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard !self.items.isEmpty else { return }
                self.startProbe()
            }
        }
    }

    // MARK: 派生数据

    var visibleItems: [ResultItem] {
        let list = items.filter { item in
            let query = filters.search.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let haystack = item.name.lowercased()
                if !haystack.contains(query.lowercased()) { return false }
            }
            if filters.excludeCam, item.isCam { return false }
            if !filters.resolutionCap.allows(item.resolutionLabel) { return false }
            if let seeders = item.seeders {
                if seeders < filters.minSeeders { return false }
                if seeders == 0 && !item.probed && filters.minSeeders == 0 { return true }
                if seeders == 0 { return false }
            }
            return true
        }
        return list.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return (lhs.seeders ?? -1) > (rhs.seeders ?? -1)
            }
            return lhs.score > rhs.score
        }
    }

    var recommendedItems: [ResultItem] {
        visibleItems.filter { ($0.seeders ?? 0) > 0 && !$0.isCam }
    }

    var aliveCount: Int { items.filter { ($0.seeders ?? 0) > 0 }.count }

    var selectedItem: ResultItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    struct Segment: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var items: [ResultItem]
    }

    var segments: [Segment] {
        let list = visibleItems
        switch filters.segment {
        case .flat:
            return [Segment(id: "flat", title: "", subtitle: "", items: list)]
        case .movie:
            let grouped = Dictionary(grouping: list) { $0.movieLabel }
            return grouped.keys.sorted { lhs, rhs in
                let left = grouped[lhs]?.first?.score ?? 0
                let right = grouped[rhs]?.first?.score ?? 0
                return left > right
            }.map { key in
                let group = grouped[key] ?? []
                let best = group.first?.score ?? 0
                return Segment(id: "movie|\(key)",
                               title: key,
                               subtitle: "\(group.count) 个版本 · 最优 \(Format.score(best)) 分",
                               items: group)
            }
        case .resolution:
            let grouped = Dictionary(grouping: list) { $0.resolutionLabel }
            let order = ["4320p", "2160p", "1080p", "720p", "480p", "—"]
            let keys = grouped.keys.sorted { lhs, rhs in
                let li = order.firstIndex(of: lhs) ?? 99
                let ri = order.firstIndex(of: rhs) ?? 99
                return li < ri
            }
            return keys.map { key in
                let group = grouped[key] ?? []
                let best = group.first?.score ?? 0
                return Segment(id: "res|\(key)",
                               title: key,
                               subtitle: "\(group.count) 个 · 最优 \(Format.score(best)) 分",
                               items: group)
            }
        }
    }

    // MARK: 解析

    func scheduleParse() {
        parseTask?.cancel()
        let text = rawInput
        parseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self.parseNow(text)
        }
    }

    func parseNow(_ text: String) {
        var parsed = LinkParser.extract(from: text)
        if text.contains("<") { LinkParser.enrichSizes(html: text, items: &parsed) }
        mergeIn(parsed)
    }

    func mergeIn(_ newcomers: [ResultItem], announce: Int? = nil) {
        var added = 0
        for var item in newcomers {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                for tracker in item.trackers where !items[index].trackers.contains(tracker) {
                    items[index].trackers.append(tracker)
                }
                if item.name.count > items[index].name.count { items[index].name = item.name }
                if item.size > items[index].size { items[index].size = item.size }
                items[index].magnet = LinkParser.magnetURI(hash: items[index].infoHash,
                                                           name: items[index].name,
                                                           trackers: items[index].trackers,
                                                           size: items[index].size)
                Self.preview(&items[index])
            } else {
                Self.preview(&item)
                items.append(item)
                added += 1
            }
        }
        if let total = announce {
            statusLine = "从网页识别到 \(total) 条链接，新增 \(added) 个种子，共 \(items.count) 条"
        } else if added > 0 {
            statusLine = "新增 \(added) 个种子，共 \(items.count) 条"
        }
    }

    /// 解析完就把片源信息算出来，表格在探测前也有内容可看
    static func preview(_ item: inout ResultItem) {
        let (quality, detail) = ReleaseParsing.score(name: item.name, size: item.size)
        item.quality = quality
        item.qualityDetail = detail
        item.group = ReleaseParsing.groupKey(item.name, kind: item.kind, hash: item.infoHash)
        if item.note == nil, item.isCam { item.note = "枪版/盗摄" }
    }

    // MARK: 文件与剪贴板

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .html, .data]
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
    }

    func loadFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            statusLine = "读不了这个文件：\(url.lastPathComponent)"
            return
        }
        var text = String(data: data, encoding: .utf8)
        if text == nil {
            let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            text = String(data: data, encoding: String.Encoding(rawValue: gbk))
        }
        guard let content = text else {
            statusLine = "文件编码认不出来：\(url.lastPathComponent)"
            return
        }
        rawInput = content
        parseNow(content)
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            statusLine = "剪贴板里没有文本"
            return
        }
        rawInput = text
        parseNow(text)
    }

    // MARK: 网页抓取

    func fetchPage() async {
        let trimmed = pageAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            statusLine = "网址要以 http:// 或 https:// 开头"
            return
        }
        await fetchPage(url: url)
    }

    func fetchPage(url: URL) async {
        isFetchingPage = true
        statusLine = "正在抓取 \(url.host ?? "网页")…"
        defer { isFetchingPage = false }
        do {
            let html = try await HTTPTracker.fetchPage(url)
            var parsed = LinkParser.extract(from: html)
            LinkParser.enrichSizes(html: html, items: &parsed)
            mergeIn(parsed, announce: parsed.count)
        } catch {
            statusLine = "抓取失败：\(error.localizedDescription)"
        }
    }

    // MARK: 探测

    func startProbe() {
        guard !isProbing, !items.isEmpty else { return }
        isProbing = true
        progressDone = 0
        progressTotal = items.count
        elapsed = 0
        statusLine = "正在探测 \(items.count) 条链接的做种数…"

        let settings = self.settings
        let started = Date()
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.elapsed = Date().timeIntervalSince(started)
            }
        }

        probeTask = Task { @MainActor in
            let batch = max(1, min(settings.workers, 24))
            var index = 0
            while index < self.items.count {
                if Task.isCancelled { break }
                let slice = Array(self.items[index..<min(index + batch, self.items.count)])
                let results = await withTaskGroup(of: ResultItem.self, returning: [ResultItem].self) { group in
                    for item in slice {
                        group.addTask { await ProbeEngine.probe(item, settings: settings) }
                    }
                    var collected: [ResultItem] = []
                    for await result in group { collected.append(result) }
                    return collected
                }
                for result in results { self.apply(result) }
                index += slice.count
            }
            self.finishProbe()
        }
    }

    private func apply(_ result: ResultItem) {
        if let index = items.firstIndex(where: { $0.id == result.id }) {
            items[index] = result
        }
        progressDone += 1
    }

    private func finishProbe() {
        isProbing = false
        tickTask?.cancel()
        let alive = aliveCount
        statusLine = "探测完成：\(items.count) 条链接，\(alive) 条有做种可用"
        if let best = recommendedItems.first {
            selectedID = best.id
        }
        if LaunchConfig.sendOnFinish {
            sendToAria(.top(3))
        }
    }

    func stopProbe() {
        probeTask?.cancel()
        probeTask = nil
        tickTask?.cancel()
        isProbing = false
        statusLine = "已停止，当前已有 \(progressDone) 条结果"
    }

    func clearAll() {
        stopProbe()
        items.removeAll()
        selectedID = nil
        rawInput = ""
        progressDone = 0
        progressTotal = 0
        elapsed = 0
        statusLine = "已清空"
    }

    // MARK: 复制 / 导出

    func copy(scope: CopyScope, withTitles: Bool = false) {
        let list: [ResultItem]
        switch scope {
        case .all: list = recommendedItems
        case .top(let count): list = Array(recommendedItems.prefix(count))
        case .selectedOnly: list = selectedItem.map { [$0] } ?? []
        }
        guard !list.isEmpty else {
            statusLine = "没有可复制的条目"
            return
        }
        let text = list.map { item in
            withTitles ? "# \(item.shortVersion)  \(item.sizeText)  做种 \(item.seedersText)\n\(item.downloadURI)" : item.downloadURI
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLine = "已复制 \(list.count) 条链接"
    }

    func copySegment(_ segment: Segment) {
        let list = segment.items.filter { ($0.seeders ?? 0) > 0 }
        guard !list.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.map { $0.downloadURI }.joined(separator: "\n"), forType: .string)
        statusLine = "已复制「\(segment.title)」的 \(list.count) 条链接"
    }

    func exportTxt() {
        export(defaultName: "magnet-picks.txt", contentType: .plainText) { items in
            items.map { $0.downloadURI }.joined(separator: "\n")
        }
    }

    func exportJSON() {
        export(defaultName: "magnet-picks.json", contentType: .json) { items in
            let rows: [[String: Any]] = items.map { item in
                [
                    "name": item.name,
                    "infoHash": item.infoHash,
                    "kind": item.kind.rawValue,
                    "size": item.size,
                    "seeders": item.seeders as Any,
                    "leechers": item.leechers as Any,
                    "score": item.score,
                    "quality": item.quality,
                    "availability": item.availability as Any,
                    "resolution": item.resolutionLabel,
                    "source": item.sourceLabel,
                    "magnet": item.downloadURI
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    private func export(defaultName: String, contentType: UTType, build: ([ResultItem]) -> String) {
        let list = recommendedItems
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = build(list)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusLine = "已导出 \(list.count) 条到 \(url.lastPathComponent)"
        } catch {
            statusLine = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: 发送到 Aria2

    func checkAria() async {
        guard ariaConfig.isConfigured else {
            ariaVersion = nil
            ariaMessage = "未配置 RPC"
            return
        }
        do {
            let version = try await Aria2Client(config: ariaConfig).version()
            ariaVersion = version
            ariaMessage = "已连接 aria2 \(version)"
        } catch {
            ariaVersion = nil
            ariaMessage = "连接失败：\(error.localizedDescription)"
        }
    }

    func sendToAria(_ scope: AriaScope) {
        let list: [ResultItem]
        switch scope {
        case .selected: list = selectedItem.map { [$0] } ?? []
        case .top(let count): list = Array(recommendedItems.prefix(count))
        case .all: list = recommendedItems
        }
        let uris = list.map { $0.downloadURI }.filter { $0.hasPrefix("magnet:") }
        guard !uris.isEmpty else {
            ariaMessage = "没有磁力链接可发送（ed2k 需要单独的下载器）"
            return
        }
        ariaBusy = true
        ariaMessage = "正在发送 \(uris.count) 条到 aria2…"
        let config = ariaConfig
        Task { @MainActor in
            do {
                let gids = try await Aria2Client(config: config).addAll(uris: uris)
                ariaBusy = false
                ariaVersion = ariaVersion ?? "已连接"
                ariaMessage = "已发送 \(gids.count) 条到 aria2（队列中）"
                statusLine = "已发送 \(gids.count) 条到 aria2"
            } catch {
                ariaBusy = false
                ariaMessage = "发送失败：\(error.localizedDescription)"
                statusLine = "aria2 发送失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 持久化

    private func loadPersisted() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "probe.settings"),
           let decoded = try? JSONDecoder().decode(ProbeSettings.self, from: data) {
            settings = decoded
        }
        if let data = defaults.data(forKey: "aria.config"),
           let decoded = try? JSONDecoder().decode(AriaConfig.self, from: data) {
            ariaConfig = decoded
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "probe.settings")
        }
    }

    private func persistAria() {
        if let data = try? JSONEncoder().encode(ariaConfig) {
            UserDefaults.standard.set(data, forKey: "aria.config")
        }
    }
}
