import Foundation

/// 够用的 bencode 解码 + DHT 报文所需的编码。
enum Bencode {
    indirect enum Value {
        case int(Int)
        case data(Data)
        case list([Value])
        case dict([String: Value])

        var intValue: Int? {
            switch self {
            case .int(let v): return v
            default: return nil
            }
        }

        var dataValue: Data? {
            switch self {
            case .data(let v): return v
            default: return nil
            }
        }

        var stringValue: String? {
            guard let data = dataValue else {
                if case .int(let v) = self { return String(v) }
                return nil
            }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }

        var listValue: [Value]? {
            if case .list(let v) = self { return v }
            return nil
        }

        var dictValue: [String: Value]? {
            if case .dict(let v) = self { return v }
            return nil
        }

        subscript(key: String) -> Value? { dictValue?[key] }
    }

    static func decode(_ data: Data) -> Value? {
        var index = data.startIndex
        return parse(data, index: &index)
    }

    private static func parse(_ data: Data, index: inout Data.Index) -> Value? {
        guard index < data.endIndex else { return nil }
        let byte = data[index]
        switch byte {
        case UInt8(ascii: "i"):
            index = data.index(after: index)
            var text = ""
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                text.append(Character(UnicodeScalar(data[index])))
                index = data.index(after: index)
            }
            index = data.index(after: index) // 跳过 e
            return Int(text).map { .int($0) }
        case UInt8(ascii: "l"):
            index = data.index(after: index)
            var items: [Value] = []
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                guard let value = parse(data, index: &index) else { return nil }
                items.append(value)
            }
            index = data.index(after: index)
            return .list(items)
        case UInt8(ascii: "d"):
            index = data.index(after: index)
            var dict: [String: Value] = [:]
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                guard let keyValue = parse(data, index: &index),
                      let key = keyValue.stringValue,
                      let value = parse(data, index: &index) else { return nil }
                dict[key] = value
            }
            index = data.index(after: index)
            return .dict(dict)
        default:
            var lengthText = ""
            while index < data.endIndex, data[index] != UInt8(ascii: ":") {
                lengthText.append(Character(UnicodeScalar(data[index])))
                index = data.index(after: index)
            }
            guard index < data.endIndex, let length = Int(lengthText) else { return nil }
            index = data.index(after: index) // 跳过 :
            let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            let slice = data[index..<end]
            index = end
            return .data(Data(slice))
        }
    }

    // MARK: 编码（DHT 报文用）

    static func encode(_ value: Value) -> Data {
        switch value {
        case .int(let v):
            return Data("i\(v)e".utf8)
        case .data(let v):
            var out = Data("\(v.count):".utf8)
            out.append(v)
            return out
        case .list(let items):
            var out = Data("l".utf8)
            for item in items { out.append(encode(item)) }
            out.append(Data("e".utf8))
            return out
        case .dict(let dict):
            var out = Data("d".utf8)
            for key in dict.keys.sorted() {
                out.append(encode(.data(Data(key.utf8))))
                out.append(encode(dict[key]!))
            }
            out.append(Data("e".utf8))
            return out
        }
    }
}
