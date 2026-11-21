import Foundation
import Darwin

/// 公共 tracker 清单：用来补全只带很少 tracker 的磁力。
enum TrackerCatalog {
    static let defaults: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.stealth.si:80/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.dler.org:6969/announce"
    ]

    static func merge(_ trackers: [String], withDefaults: Bool) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tracker in trackers + (withDefaults ? defaults : []) {
            let normalized = tracker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }
}

enum NetworkError: LocalizedError {
    case badURL
    case timeout
    case empty
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .timeout: return "超时"
        case .empty: return "无响应"
        case .transport(let text): return text
        }
    }
}

enum HTTPTracker {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "MagnetPicker/1.0"]
        return URLSession(configuration: config)
    }()

    // MARK: 抓网页

    static func fetchPage(_ url: URL, timeout: Double = 12) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw NetworkError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var text = String(data: data, encoding: .utf8)
        if text == nil {
            let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            text = String(data: data, encoding: String.Encoding(rawValue: gbk))
        }
        guard let page = text else { throw NetworkError.transport("解码失败") }
        return page
    }

    // MARK: scrape（BEP 48，只读）

    static func scrape(infoHash: String, tracker: String, timeout: Double) async -> TrackerHit {
        if tracker.hasPrefix("udp://") {
            return await UDPTracker.scrape(infoHash: infoHash, tracker: tracker, timeout: timeout)
        }
        guard let url = scrapeURL(infoHash: infoHash, tracker: tracker) else {
            return TrackerHit(tracker: tracker, message: "不支持的协议")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, _) = try await session.data(for: request)
            if let result = parseScrape(data, infoHash: infoHash) {
                return TrackerHit(tracker: tracker, seeders: result.0, leechers: result.1)
            }
        } catch {
            // HTTP scrape 不被支持或超时：直接返回失败，不再补 announce（否则耗时翻倍）
            return TrackerHit(tracker: tracker, message: error.localizedDescription.contains("timed out") ? "超时" : "无响应")
        }
        return await announce(infoHash: infoHash, tracker: tracker, timeout: timeout)
    }

    static func scrapeURL(infoHash: String, tracker: String) -> URL? {
        var base = tracker
        if base.hasPrefix("https://") { base.removeFirst(8) } else if base.hasPrefix("http://") { base.removeFirst(7) }
        guard let range = base.range(of: "announce", options: .backwards) else { return nil }
        base.replaceSubrange(range, with: "scrape")
        let escaped = escapeHash(infoHash)
        return URL(string: "http://" + base + (base.contains("?") ? "&" : "?") + "info_hash=" + escaped)
    }

    static func parseScrape(_ data: Data, infoHash: String) -> (Int, Int)? {
        guard let root = Bencode.decode(data),
              let files = root["files"]?.dictValue, !files.isEmpty else { return nil }
        let binaryHash = Data(hexString: infoHash)
        for (key, value) in files {
            let keyData = key.data(using: .isoLatin1)
            if key == infoHash || keyData == binaryHash || key.lowercased() == infoHash {
                let complete = value["complete"]?.intValue ?? 0
                let incomplete = value["incomplete"]?.intValue ?? 0
                return (complete, incomplete)
            }
        }
        if let first = files.values.first {
            return (first["complete"]?.intValue ?? 0, first["incomplete"]?.intValue ?? 0)
        }
        return nil
    }

    // MARK: announce（numwant=0，不占 peer 名额）

    static func announce(infoHash: String, tracker: String, timeout: Double) async -> TrackerHit {
        guard var components = URLComponents(string: tracker), tracker.hasPrefix("http") else {
            return TrackerHit(tracker: tracker, message: "不支持")
        }
        let peerId = "-MP0001-" + String(format: "%012d", abs(infoHash.hashValue % 1_000_000_000_000))
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "info_hash", value: Data(hexString: infoHash).percentEscaped),
            URLQueryItem(name: "peer_id", value: peerId),
            URLQueryItem(name: "port", value: "6881"),
            URLQueryItem(name: "uploaded", value: "0"),
            URLQueryItem(name: "downloaded", value: "0"),
            URLQueryItem(name: "left", value: "0"),
            URLQueryItem(name: "compact", value: "1"),
            URLQueryItem(name: "numwant", value: "0"),
            URLQueryItem(name: "event", value: "started")
        ])
        components.queryItems = items
        guard let url = components.url else { return TrackerHit(tracker: tracker, message: "地址无效") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, _) = try await session.data(for: request)
            guard let root = Bencode.decode(data) else {
                return TrackerHit(tracker: tracker, message: "返回异常")
            }
            if let failure = root["failure reason"]?.stringValue {
                return TrackerHit(tracker: tracker, message: failure)
            }
            return TrackerHit(tracker: tracker,
                              seeders: root["complete"]?.intValue,
                              leechers: root["incomplete"]?.intValue)
        } catch {
            return TrackerHit(tracker: tracker,
                              message: error.localizedDescription.contains("timed out") ? "超时" : "无响应")
        }
    }

    static func escapeHash(_ infoHash: String) -> String {
        Data(hexString: infoHash).percentEscaped
    }
}

// MARK: - UDP tracker（BEP 15）

enum UDPTracker {
    static func scrape(infoHash: String, tracker: String, timeout: Double) async -> TrackerHit {
        guard let rawHost = URLComponents(string: tracker)?.host else {
            return TrackerHit(tracker: tracker, message: "地址无效")
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = UInt16(URLComponents(string: tracker)?.port ?? 6969)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
            guard socketFD >= 0 else { return TrackerHit(tracker: tracker, message: "socket 失败") }
            defer { close(socketFD) }

            guard var address = resolve(host: host, port: port) else {
                return TrackerHit(tracker: tracker, message: "域名解析失败")
            }

            let transaction = UInt32.random(in: 1...UInt32.max)
            var connectRequest = Data()
            connectRequest.append(bigEndian: UInt64(0x41727101980))
            connectRequest.append(bigEndian: UInt32(0))
            connectRequest.append(bigEndian: transaction)

            try send(connectRequest, fd: socketFD, address: &address)
            guard let connectReply = try await receive(fd: socketFD, deadline: deadline, expect: 16),
                  readUInt32(connectReply, 0) == 0,
                  readUInt32(connectReply, 4) == transaction else {
                return TrackerHit(tracker: tracker, message: "connect 无响应")
            }
            let connectionId = readUInt64(connectReply, 8)

            var scrapeRequest = Data()
            scrapeRequest.append(bigEndian: connectionId)
            scrapeRequest.append(bigEndian: UInt32(2))
            scrapeRequest.append(bigEndian: transaction)
            scrapeRequest.append(Data(hexString: infoHash))

            try send(scrapeRequest, fd: socketFD, address: &address)
            guard let reply = try await receive(fd: socketFD, deadline: deadline, expect: 20),
                  readUInt32(reply, 0) == 2,
                  readUInt32(reply, 4) == transaction else {
                return TrackerHit(tracker: tracker, message: "scrape 无响应")
            }
            let seeders = Int(readUInt32(reply, 8))
            let leechers = Int(readUInt32(reply, 16))
            return TrackerHit(tracker: tracker, seeders: seeders, leechers: leechers)
        } catch {
            return TrackerHit(tracker: tracker, message: (error as? NetworkError)?.errorDescription ?? "无响应")
        }
    }

    private static func resolve(host: String, port: UInt16) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_family = UInt8(AF_INET)
        address.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &address.sin_addr) == 1 { return address }

        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        guard let pointer = first.pointee.ai_addr else { return nil }
        return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    private static func send(_ data: Data, fd: Int32, address: inout sockaddr_in) throws {
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.sendto(fd, (data as NSData).bytes, data.count, 0, sockaddrPointer, UInt32(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result < 0 { throw NetworkError.transport("发送失败") }
    }

    private static func receive(fd: Int32, deadline: Date, expect: Int) async throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(50, deadline.timeIntervalSinceNow * 1000))
            let ready = poll(&descriptor, 1, remaining)
            if ready > 0 {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count >= 8 {
                    let data = Data(bytes: buffer, count: count)
                    if data.count >= expect { return data }
                }
            } else if ready < 0 {
                throw NetworkError.transport("轮询失败")
            }
        }
        return nil
    }

    static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
    }

    static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        guard data.count >= offset + 8 else { return 0 }
        return data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
    }
}

// MARK: - Data 工具

extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            let pair = hexString[index..<next]
            if let byte = UInt8(pair, radix: 16) { bytes.append(byte) }
            index = next
        }
        self.init(bytes)
    }

    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { buffer in
            append(contentsOf: buffer)
        }
    }

    /// tracker 查询串里 info_hash 要按字节百分号转义
    var percentEscaped: String {
        map { String(format: "%%%02X", $0) }.joined()
    }
}
