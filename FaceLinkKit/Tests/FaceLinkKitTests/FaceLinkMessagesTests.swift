import Testing
import simd
@testable import FaceLinkKit

private func fullFrame() -> FaceFrame {
    var shapes: [BlendShape: Float] = [:]
    for (index, shape) in BlendShape.allCases.enumerated() {
        shapes[shape] = Float(index) / 51
    }
    return FaceFrame(
        blendShapes: shapes,
        head: Pose(position: SIMD3(0.01, -0.02, 0.03), rotation: simd_quatf(angle: 0.2, axis: SIMD3(0, 1, 0))),
        leftEye: simd_quatf(angle: 0.1, axis: SIMD3(1, 0, 0)),
        rightEye: simd_quatf(angle: -0.1, axis: SIMD3(1, 0, 0))
    )
}

private func decode(_ datagrams: [[UInt8]]) throws -> [OSCMessage] {
    try datagrams.flatMap { try OSCDecoder.messages(in: $0) }
}

/// 52개를 다 넣으면 1,400바이트를 넘으므로 나뉘고, 나뉜 데이터그램은 모두 1,400바이트 이하
@Test func fullFrameIsSplitIntoDatagramsOfAtMost1400Bytes() throws {
    let datagrams = FaceLinkEncoder().datagrams(for: fullFrame(), sequence: 7, time: 1.5)
    #expect(datagrams.count >= 2)
    for datagram in datagrams {
        #expect(datagram.count <= FaceLinkProtocol.maxDatagramSize)
        #expect(datagram.starts(with: Array("#bundle".utf8) + [0, 0, 0, 0, 0, 0, 0, 0, 1]))
    }
}

/// 순서: Frame → Bone(Head, LeftEye, RightEye) → Val ×52 (부록 A 순서) → Apply
@Test func frameMessageOrder() throws {
    let frame = fullFrame()
    let messages = try decode(FaceLinkEncoder().datagrams(for: frame, sequence: 7, time: 1.5))
    #expect(messages.count == 1 + 3 + 52 + 1)
    #expect(messages.first == FaceLinkMessage.frame(sequence: 7, time: 1.5, isTracked: true))
    #expect(messages[1].address == "/VMC/Ext/Bone/Pos")
    #expect(messages[1].arguments.first == .string("Head"))
    #expect(messages[2].arguments.first == .string("LeftEye"))
    #expect(messages[3].arguments.first == .string("RightEye"))
    let values = messages[4..<56]
    #expect(values.map(\.address).allSatisfy { $0 == "/VMC/Ext/Blend/Val" })
    #expect(values.map { $0.arguments[0] } == BlendShape.allCases.map { OSCArgument.string($0.name) })
    #expect(values.map { $0.arguments[1] } == BlendShape.allCases.map { OSCArgument.float(frame.blendShapes[$0]!) })
    #expect(messages.last == FaceLinkMessage.blendApply)
}

/// 머리 자세는 Unity 좌표로: 위치 (x, y, −z), 쿼터니언 (−qx, −qy, qz, qw)
@Test func headBoneUsesUnityCoordinates() throws {
    let frame = fullFrame()
    let messages = FaceLinkEncoder().messages(for: frame, sequence: 1, time: 0)
    let q = frame.head.rotation
    #expect(messages[1].arguments == [
        .string("Head"), .float(0.01), .float(-0.02), .float(-0.03),
        .float(-q.imag.x), .float(-q.imag.y), .float(q.imag.z), .float(q.real),
    ])
    // 눈은 위치 0
    #expect(Array(messages[2].arguments[1...3]) == [.float(0), .float(0), .float(0)])
}

@Test func encoderOptions() {
    let frame = fullFrame()
    let noEyes = FaceLinkEncoder(sendEyes: false).messages(for: frame, sequence: 1, time: 0)
    #expect(noEyes.filter { $0.address == "/VMC/Ext/Bone/Pos" }.count == 1)
    let noPosition = FaceLinkEncoder(sendHeadPosition: false).messages(for: frame, sequence: 1, time: 0)
    #expect(Array(noPosition[1].arguments[1...3]) == [.float(0), .float(0), .float(0)])
    // 없는 이름은 0, 범위 밖 값은 0~1로
    var partial = FaceFrame(blendShapes: [.jawOpen: 1.7, .eyeBlinkLeft: -0.2])
    partial.leftEye = nil
    let values = FaceLinkEncoder().messages(for: partial, sequence: 1, time: 0).filter { $0.address == "/VMC/Ext/Blend/Val" }
    #expect(values.count == 52)
    func value(_ name: String) -> OSCArgument? {
        values.first { $0.arguments[0] == OSCArgument.string(name) }?.arguments[1]
    }
    #expect(value("JawOpen") == OSCArgument.float(1))
    #expect(value("EyeBlinkLeft") == OSCArgument.float(0))
    #expect(value("MouthClose") == OSCArgument.float(0))
}

/// 얼굴을 놓친 프레임은 Frame(추적 상태 0)과 Apply만
@Test func lostFrameHasOnlyFrameAndApply() {
    let messages = FaceLinkEncoder().messages(for: .lost, sequence: 3, time: 2)
    #expect(messages == [FaceLinkMessage.frame(sequence: 3, time: 2, isTracked: false), FaceLinkMessage.blendApply])
}

@Test func helloArguments() {
    let hello = FaceLinkMessage.hello(deviceName: "내 iPhone", appVersion: "0.1.12", sessionID: "S", token: "")
    #expect(hello.address == "/FaceLink/Hello")
    #expect(hello.arguments == [.string("1"), .string("내 iPhone"), .string("0.1.12"), .string("S"), .string(""), .string("face")])
    // v1.1 기능: 넣은 순서와 상관없이 face,body,hands,audio 순서
    let all = FaceLinkMessage.hello(deviceName: "d", appVersion: "v", sessionID: "S", token: "t", features: [.audio, .hands, .face, .body])
    #expect(all.arguments.last == .string("face,body,hands,audio"))
    #expect(FaceLinkFeature.list([.audio, .face]) == "face,audio")
}

@Test func inboundMessages() {
    #expect(FaceLinkInbound(FaceLinkMessage.ack(lastSequence: 9, receiverFPS: 59.5, receiverName: "iPad"))
        == .ack(FaceLinkAck(lastSequence: 9, receiverFPS: 59.5, receiverName: "iPad")))
    #expect(FaceLinkInbound(FaceLinkMessage.calibrate) == .calibrate)
    // 남는 인자는 무시, 형식이 다르거나 모르는 주소는 nil
    #expect(FaceLinkInbound(OSCMessage("/FaceLink/Ack", [.int(1), .float(2), .string("a"), .int(4)])) != nil)
    #expect(FaceLinkInbound(OSCMessage("/FaceLink/Ack", [.int(1), .float(2)])) == nil)
    #expect(FaceLinkInbound(OSCMessage("/FaceLink/Ack", [.float(1), .float(2), .string("a")])) == nil)
    #expect(FaceLinkInbound(OSCMessage("/VMC/Ext/OK", [.int(1)])) == nil)
}

@Test func sessionSequenceWrapsToZero() {
    var session = FaceLinkSession(startTime: 100)
    #expect(session.takeSequence() == 1)
    #expect(session.takeSequence() == 2)
    #expect(session.time(at: 101.5) == 1.5)
    var wrapping = FaceLinkSession(startTime: 0, firstSequence: .max)
    #expect(wrapping.takeSequence() == .max)
    #expect(wrapping.takeSequence() == 0)
    #expect(FaceLinkSession(startTime: 0).id != FaceLinkSession(startTime: 0).id)
}

@Test func roundTripTracker() {
    var tracker = RoundTripTracker(capacity: 4)
    tracker.recordSent(10, at: 1.0)
    tracker.recordSent(11, at: 1.1)
    #expect(tracker.roundTrip(forAck: 10, receivedAt: 1.05) == 1.05 - 1.0)
    #expect(tracker.roundTrip(forAck: 12, receivedAt: 2) == nil)
    // 같은 칸을 덮어쓴 오래된 순번은 잊는다
    tracker.recordSent(14, at: 1.4)
    #expect(tracker.roundTrip(forAck: 10, receivedAt: 2) == nil)
    #expect(tracker.roundTrip(forAck: 14, receivedAt: 1.5) == 1.5 - 1.4)
    // 순번 0과 최댓값
    tracker.recordSent(.max, at: 3)
    tracker.recordSent(0, at: 3.1)
    #expect(tracker.roundTrip(forAck: .max, receivedAt: 3.2) == 3.2 - 3)
    #expect(tracker.roundTrip(forAck: 0, receivedAt: 3.2) == 3.2 - 3.1)
}
