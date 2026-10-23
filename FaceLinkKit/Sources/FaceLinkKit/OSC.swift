import Foundation

/// OSC 1.0 인자. FaceLink는 문자열·int32·float32만 쓴다 (docs/face-link.md 3.1)
public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)

    var typeTag: Character {
        switch self {
        case .int: "i"
        case .float: "f"
        case .string: "s"
        }
    }
}

/// OSC 메시지 하나
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    /// 빅 엔디언, 4바이트 정렬
    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        bytes.appendOSCString(address)
        bytes.appendOSCString("," + String(arguments.map(\.typeTag)))
        for argument in arguments {
            switch argument {
            case .int(let value): bytes.appendBigEndian(UInt32(bitPattern: value))
            case .float(let value): bytes.appendBigEndian(value.bitPattern)
            case .string(let value): bytes.appendOSCString(value)
            }
        }
        return bytes
    }
}

public enum OSCBundle {
    /// time tag 1 = "즉시"
    public static let immediately: UInt64 = 1
    static let marker: [UInt8] = Array("#bundle".utf8) + [0]
    /// "#bundle\0" 8바이트 + time tag 8바이트
    static let headerSize = 16

    /// 이미 인코딩한 요소(메시지 또는 번들)들을 번들 하나로. 요소마다 앞에 크기(int32)가 붙는다
    public static func encode(_ elements: [[UInt8]], timeTag: UInt64 = immediately) -> [UInt8] {
        var bytes = marker
        bytes.appendBigEndian(timeTag)
        for element in elements {
            bytes.appendBigEndian(UInt32(element.count))
            bytes.append(contentsOf: element)
        }
        return bytes
    }

    /// 메시지들을 순서대로 번들에 담되, 번들 하나가 maxSize 바이트를 넘지 않게 여러 개로 나눈다.
    /// 메시지 하나만으로 넘으면 그 메시지만 든 번들이 된다 (FaceLink 메시지는 그렇게 크지 않다)
    public static func pack(_ messages: [OSCMessage], maxSize: Int) -> [[UInt8]] {
        var bundles: [[UInt8]] = []
        var current: [[UInt8]] = []
        var size = headerSize
        for message in messages {
            let element = message.encoded()
            let elementSize = 4 + element.count
            if !current.isEmpty && size + elementSize > maxSize {
                bundles.append(encode(current))
                current = []
                size = headerSize
            }
            current.append(element)
            size += elementSize
        }
        if !current.isEmpty {
            bundles.append(encode(current))
        }
        return bundles
    }
}

public enum OSCDecodeError: Error, Equatable {
    case truncated
    case invalidString
    case invalidAddress
    case invalidTypeTags
    case unsupportedType(Character)
    case invalidBundle
}

public enum OSCDecoder {
    /// 패킷(메시지 또는 번들) 안의 메시지를 순서대로 꺼낸다. 번들 안의 번들도 푼다
    public static func messages(in packet: [UInt8]) throws -> [OSCMessage] {
        var messages: [OSCMessage] = []
        try decode(packet[...], into: &messages)
        return messages
    }

    private static func decode(_ packet: ArraySlice<UInt8>, into messages: inout [OSCMessage]) throws {
        guard let first = packet.first else { throw OSCDecodeError.truncated }
        if first == UInt8(ascii: "#") {
            guard packet.starts(with: OSCBundle.marker) else { throw OSCDecodeError.invalidBundle }
            var reader = OSCReader(packet.dropFirst(OSCBundle.marker.count))
            _ = try reader.uint64() // time tag: FaceLink는 늘 "즉시"라 보지 않는다
            while !reader.isAtEnd {
                let size = Int(try reader.uint32())
                guard size > 0 else { throw OSCDecodeError.invalidBundle }
                try decode(try reader.bytes(size), into: &messages)
            }
        } else {
            var reader = OSCReader(packet)
            messages.append(try reader.message())
        }
    }
}

private struct OSCReader {
    let data: ArraySlice<UInt8>
    var index: Int

    init(_ data: ArraySlice<UInt8>) {
        self.data = data
        index = data.startIndex
    }

    var isAtEnd: Bool { index >= data.endIndex }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, data.endIndex - index >= count else { throw OSCDecodeError.truncated }
        defer { index += count }
        return data[index..<index + count]
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try bytes(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// 널로 끝나고 4바이트 정렬된 문자열 (정렬은 이 리더의 처음, 곧 메시지 처음 기준)
    mutating func string() throws -> String {
        guard let end = data[index...].firstIndex(of: 0) else { throw OSCDecodeError.truncated }
        guard let string = String(bytes: data[index..<end], encoding: .utf8) else { throw OSCDecodeError.invalidString }
        let next = data.startIndex + ((end - data.startIndex + 4) & ~3)
        guard next <= data.endIndex else { throw OSCDecodeError.truncated }
        index = next
        return string
    }

    mutating func message() throws -> OSCMessage {
        let address = try string()
        guard address.hasPrefix("/") else { throw OSCDecodeError.invalidAddress }
        // 타입 태그 문자열이 없는 옛 형식은 인자 없음으로 본다
        if isAtEnd { return OSCMessage(address) }
        let tags = try string()
        guard tags.hasPrefix(",") else { throw OSCDecodeError.invalidTypeTags }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int(Int32(bitPattern: try uint32())))
            case "f": arguments.append(.float(Float(bitPattern: try uint32())))
            case "s": arguments.append(.string(try string()))
            default: throw OSCDecodeError.unsupportedType(tag)
            }
        }
        return OSCMessage(address, arguments)
    }
}

extension [UInt8] {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// UTF-8 바이트 + 널, 그리고 길이가 4의 배수가 되게 널을 더 붙인다 (배열 처음 기준)
    mutating func appendOSCString(_ string: String) {
        append(contentsOf: string.utf8)
        append(0)
        while count % 4 != 0 {
            append(0)
        }
    }
}
