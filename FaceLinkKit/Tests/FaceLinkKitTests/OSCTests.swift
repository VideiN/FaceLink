import Testing
@testable import FaceLinkKit

private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

private func concat(_ parts: [UInt8]...) -> [UInt8] {
    parts.flatMap { $0 }
}

@Test func stringsAreNullTerminatedAndPaddedToFourBytes() {
    var data: [UInt8] = []
    data.appendOSCString("abc")
    #expect(data == bytes("abc") + [0])
    data = []
    data.appendOSCString("abcd")
    #expect(data == bytes("abcd") + [0, 0, 0, 0])
    data = []
    data.appendOSCString("")
    #expect(data == [0, 0, 0, 0])
}

/// 부록 B의 첫 메시지: /FaceLink/Frame ,ifi 1234 532.016 1
@Test func frameMessageBytes() {
    let message = OSCMessage("/FaceLink/Frame", [.int(1234), .float(532.016), .int(1)])
    let floatBits = Float(532.016).bitPattern
    let floatBytes: [UInt8] = [
        UInt8(floatBits >> 24), UInt8(floatBits >> 16 & 0xFF), UInt8(floatBits >> 8 & 0xFF), UInt8(floatBits & 0xFF),
    ]
    let expected = concat(
        bytes("/FaceLink/Frame"), [0], // 15자 + 널 = 16
        bytes(",ifi"), [0, 0, 0, 0], // 4자 + 널 → 8
        [0, 0, 0x04, 0xD2],
        floatBytes,
        [0, 0, 0, 1]
    )
    #expect(message.encoded() == expected)
}

/// 인자가 없어도 타입 태그 ","는 넣는다
@Test func applyMessageBytes() {
    let message = OSCMessage("/VMC/Ext/Blend/Apply")
    #expect(message.encoded() == concat(bytes("/VMC/Ext/Blend/Apply"), [0, 0, 0, 0], bytes(","), [0, 0, 0]))
}

@Test func bundleBytes() {
    let element = OSCMessage("/a").encoded()
    #expect(element == concat(bytes("/a"), [0, 0], bytes(","), [0, 0, 0]))
    let bundle = OSCBundle.encode([element])
    #expect(bundle == concat(bytes("#bundle"), [0], [0, 0, 0, 0, 0, 0, 0, 1], [0, 0, 0, 8], element))
}

@Test func encodeDecodeRoundTrip() throws {
    let messages = [
        OSCMessage("/VMC/Ext/Blend/Val", [.string("EyeBlinkLeft"), .float(0.25)]),
        OSCMessage("/FaceLink/Hello", [.string("1"), .string("내 iPhone"), .string("0.1.12"), .string("6F1C"), .string("")]),
        OSCMessage("/FaceLink/Frame", [.int(-5), .float(-1.5), .int(Int32.max)]),
        OSCMessage("/VMC/Ext/Blend/Apply"),
    ]
    for message in messages {
        #expect(try OSCDecoder.messages(in: message.encoded()) == [message])
    }
    let bundle = OSCBundle.encode(messages.map { $0.encoded() })
    #expect(try OSCDecoder.messages(in: bundle) == messages)
    // 번들 안의 번들
    let nested = OSCBundle.encode([bundle, messages[0].encoded()])
    #expect(try OSCDecoder.messages(in: nested) == messages + [messages[0]])
}

@Test func packSplitsBundlesAtMaxSize() throws {
    let messages = (0..<100).map { OSCMessage("/VMC/Ext/Blend/Val", [.string("Shape\($0)"), .float(Float($0) / 100)]) }
    let datagrams = OSCBundle.pack(messages, maxSize: 300)
    #expect(datagrams.count > 1)
    for datagram in datagrams {
        #expect(datagram.count <= 300)
    }
    #expect(try datagrams.flatMap { try OSCDecoder.messages(in: $0) } == messages)
    // 한 번들에 다 들어가면 하나
    #expect(OSCBundle.pack(Array(messages.prefix(2)), maxSize: 1400).count == 1)
}

@Test func decodeRejectsBrokenPackets() {
    let message = OSCMessage("/FaceLink/Frame", [.int(1), .float(2), .int(1)]).encoded()
    #expect(throws: OSCDecodeError.truncated) { try OSCDecoder.messages(in: Array(message.dropLast(2))) }
    #expect(throws: OSCDecodeError.truncated) { try OSCDecoder.messages(in: []) }
    #expect(throws: OSCDecodeError.invalidAddress) { try OSCDecoder.messages(in: concat(bytes("abc"), [0])) }
    #expect(throws: OSCDecodeError.unsupportedType("d")) {
        try OSCDecoder.messages(in: concat(bytes("/x"), [0, 0], bytes(",d"), [0, 0], [0, 0, 0, 0, 0, 0, 0, 0]))
    }
    #expect(throws: OSCDecodeError.invalidBundle) { try OSCDecoder.messages(in: concat(bytes("#bundlx"), [0])) }
    // 번들 요소 크기가 남은 길이보다 크다
    var bundle = OSCBundle.encode([message])
    bundle.removeLast(4)
    #expect(throws: OSCDecodeError.truncated) { try OSCDecoder.messages(in: bundle) }
}
