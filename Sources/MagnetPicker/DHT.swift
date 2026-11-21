import Foundation
import Darwin

/// 极简 DHT 嗅探：只在 tracker 完全没数据时兜底，统计一下 get_peers 的活跃节点。
enum DHT {
    private static let routers: [(String, UInt16)] = [
        ("dht.transmissionbt.com", 6881),
        ("router.bittorrent.com", 6881),
        ("dht.aelitis.com", 6881)
    ]

    static func peerCount(infoHash: String, timeout: Double) async -> Int {
        let hash = Data(hexString: infoHash)
        guard hash.count == 20 else { return 0 }

        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return 0 }
        defer { close(socketFD) }

        let deadline = Date().addingTimeInterval(timeout)
        let nodeId = randomBytes(20)
        var peers = Set<String>()

        for router in routers where Date() < deadline {
            guard let address = resolve(host: router.0, port: router.1) else { continue }
            let tid = Data(randomBytes(2))
            let query = Bencode.Value.dict([
                "a": .dict(["id": .data(nodeId), "info_hash": .data(hash)]),
                "q": .data(Data("get_peers".utf8)),
                "t": .data(tid),
                "y": .data(Data("q".utf8))
            ])
            let payload = Bencode.encode(query)
            var addressCopy = address
            _ = withUnsafePointer(to: &addressCopy) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(socketFD, (payload as NSData).bytes, payload.count, 0,
                                  sockaddrPointer, UInt32(MemoryLayout<sockaddr_in>.size))
                }
            }

            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
                let wait = Int32(max(60, min(deadline.timeIntervalSinceNow, 1.5) * 1000))
                let ready = poll(&descriptor, 1, wait)
                guard ready > 0 else { break }
                let count = recv(socketFD, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                let data = Data(bytes: buffer, count: count)
                guard let root = Bencode.decode(data), let response = root["r"] else { continue }
                if let values = response["values"]?.listValue {
                    for value in values {
                        if let bytes = value.dataValue, bytes.count >= 6 {
                            let ip = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
                            let port = Int(bytes[4]) << 8 | Int(bytes[5])
                            peers.insert("\(ip):\(port)")
                        }
                    }
                }
                if let nodes = response["nodes"]?.dataValue {
                    // compact 节点表：每个节点 20 字节 ID + 6 字节地址
                    let total = nodes.count / 26
                    if total > 0 { peers.insert("nodes:~\(total)") }
                }
            }
        }
        return peers.count
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
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
}
