import Foundation

// MARK: - 探测缓存

struct CacheEntry: Codable {
    var seeders: Int?
    var leechers: Int?
    var message: String?
    var updated: Date
}

final class ProbeCache {
    static let shared = ProbeCache()

    private var entries: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private var loaded = false

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return base.appendingPathComponent("MagnetPicker", isDirectory: true)
            .appendingPathComponent("probe-cache.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        entries = decoded
    }

    func get(hash: String, tracker: String, ttl: Double) -> CacheEntry? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let entry = entries["\(hash)|\(tracker)"] else { return nil }
        if Date().timeIntervalSince(entry.updated) > ttl { return nil }
        return entry
    }

    func set(hash: String, tracker: String, entry: CacheEntry) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        entries["\(hash)|\(tracker)"] = entry
        scheduleSave()
    }

    private var saveScheduled = false

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.save()
        }
    }

    private func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 探测引擎

enum ProbeEngine {

    static func probe(_ item: ResultItem, settings: ProbeSettings) async -> ResultItem {
        guard item.kind == .magnet else {
            return finalize(item, hits: [], dhtPeers: 0, weight: settings.weightAvailability)
        }

        let trackers = Array(TrackerCatalog.merge(item.trackers, withDefaults: settings.useDefaultTrackers)
            .prefix(max(1, settings.maxTrackers)))

        var hits: [TrackerHit] = []
        // 一条链接内部同时最多问 4 个 tracker，整体并发由 AppModel 的批大小控制
        let perItemConcurrency = 4
        for slice in stride(from: 0, to: trackers.count, by: perItemConcurrency).map({ Array(trackers[$0..<min($0 + perItemConcurrency, trackers.count)]) }) {
        await withTaskGroup(of: TrackerHit.self) { group in
            for tracker in slice {
                group.addTask {
                    if let cached = ProbeCache.shared.get(hash: item.infoHash, tracker: tracker, ttl: settings.cacheTTL) {
                        var hit = TrackerHit(tracker: tracker, seeders: cached.seeders, leechers: cached.leechers, message: cached.message)
                        hit.cached = true
                        return hit
                    }
                    let hit = await HTTPTracker.scrape(infoHash: item.infoHash, tracker: tracker, timeout: settings.trackerTimeout)
                    ProbeCache.shared.set(hash: item.infoHash, tracker: tracker,
                                          entry: CacheEntry(seeders: hit.seeders, leechers: hit.leechers,
                                                            message: hit.message, updated: Date()))
                    return hit
                }
            }
            for await hit in group { hits.append(hit) }
        }
        }

        var dhtPeers = 0
        if settings.useDHT, trackers.isEmpty || hits.allSatisfy({ !$0.ok }) {
            dhtPeers = await DHT.peerCount(infoHash: item.infoHash, timeout: settings.dhtTimeout)
        }

        return finalize(item, hits: hits, dhtPeers: dhtPeers, weight: settings.weightAvailability)
    }

    /// 收尾：合并 tracker 结果、算质量与综合分
    static func finalize(_ item: ResultItem, hits: [TrackerHit], dhtPeers: Int, weight: Double) -> ResultItem {
        var result = item
        result.trackerHits = hits.sorted { ($0.seeders ?? -1) > ($1.seeders ?? -1) }
        let ok = hits.filter { $0.seeders != nil }
        result.trackerOK = ok.count
        result.trackerFail = hits.count - ok.count
        result.seeders = ok.compactMap { $0.seeders }.max()
        result.leechers = ok.compactMap { $0.leechers }.max()
        result.dhtPeers = dhtPeers

        let (quality, detail) = ReleaseParsing.score(name: result.name, size: result.size)
        result.quality = quality
        result.qualityDetail = detail
        result.availability = ReleaseParsing.availability(seeders: result.seeders,
                                                        dhtPeers: dhtPeers,
                                                        kind: result.kind)
        result.score = ReleaseParsing.total(availability: result.availability,
                                            quality: quality,
                                            isCam: result.isCam,
                                            weight: weight)
        result.group = ReleaseParsing.groupKey(result.name, kind: result.kind, hash: result.infoHash)
        result.probed = true

        if result.isCam {
            result.note = "枪版/盗摄"
        } else if let s = result.seeders, s == 0 {
            result.note = "当前无做种"
        } else if let s = result.seeders, s < 3 {
            result.note = "做种偏少"
        }
        return result
    }
}
