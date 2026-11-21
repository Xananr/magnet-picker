import Foundation

// MARK: - Aria2 连接配置

struct AriaConfig: Codable, Equatable {
    var rpcURL: String = "http://127.0.0.1:6800/jsonrpc"
    var secret: String = ""
    var savePath: String = ""

    var isConfigured: Bool { !rpcURL.isEmpty }
}

enum AriaError: LocalizedError {
    case badURL
    case http(Int)
    case rpc(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .badURL: return "RPC 地址无效"
        case .http(let code): return "RPC 返回 HTTP \(code)"
        case .rpc(let text): return text
        case .emptyResult: return "RPC 返回空结果"
        }
    }
}

/// aria2 JSON-RPC 客户端：只用 addUri / getVersion / getGlobalStat 这三个方法。
struct Aria2Client {
    let config: AriaConfig

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    func request(method: String, params: [Any]) async throws -> Any {
        guard let url = URL(string: config.rpcURL), url.scheme != nil else { throw AriaError.badURL }
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]
        if !config.secret.isEmpty {
            var withSecret: [Any] = ["token:\(config.secret)"]
            withSecret.append(contentsOf: params)
            payload["params"] = withSecret
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw AriaError.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AriaError.emptyResult
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "未知错误"
            throw AriaError.rpc(message)
        }
        guard let result = object["result"] else { throw AriaError.emptyResult }
        return result
    }

    func version() async throws -> String {
        let result = try await request(method: "aria2.getVersion", params: [])
        guard let dict = result as? [String: Any], let version = dict["version"] as? String else {
            throw AriaError.emptyResult
        }
        return version
    }

    /// 一条链接一次调用；aria2 的 addUri 会把同一个数组里的 URI 视为同一个任务的多来源。
    func add(uri: String) async throws -> String {
        var options: [String: Any] = [:]
        let path = config.savePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { options["dir"] = path }
        options["pause"] = "false"

        let result = try await request(method: "aria2.addUri", params: [[uri], options])
        guard let gid = result as? String else { throw AriaError.emptyResult }
        return gid
    }

    func addAll(uris: [String]) async throws -> [String] {
        var gids: [String] = []
        for uri in uris {
            let gid = try await add(uri: uri)
            gids.append(gid)
        }
        return gids
    }

    struct GlobalStat {
        var downloadSpeed: String
        var active: Int
        var waiting: Int
        var stopped: Int
    }

    func globalStat() async throws -> GlobalStat {
        let result = try await request(method: "aria2.getGlobalStat", params: [])
        guard let dict = result as? [String: Any] else { throw AriaError.emptyResult }
        let speed = Int(dict["downloadSpeed"] as? String ?? "0") ?? 0
        return GlobalStat(downloadSpeed: Aria2Client.humanSpeed(speed),
                          active: Int(dict["numActive"] as? String ?? "0") ?? 0,
                          waiting: Int(dict["numWaiting"] as? String ?? "0") ?? 0,
                          stopped: Int(dict["numStopped"] as? String ?? "0") ?? 0)
    }

    static func humanSpeed(_ bytesPerSecond: Int) -> String {
        if bytesPerSecond <= 0 { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSecond)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
