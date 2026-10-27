import Testing
import simd
@testable import FaceLinkKit

private func boneName(_ message: OSCMessage) -> String? {
    guard message.address == FaceLinkProtocol.Address.bonePosition, case .string(let name) = message.arguments.first else { return nil }
    return name
}

private func quaternionLength(_ message: OSCMessage) -> Float {
    let values = message.arguments[4...7].compactMap { argument -> Float? in
        if case .float(let value) = argument { return value }
        return nil
    }
    return values.map { $0 * $0 }.reduce(0, +).squareRoot()
}

/// Unity HumanBodyBones와 같은 55개, 같은 순서 (Broadcast 받는 쪽도 이 순서)
@Test func humanBoneNames() {
    let names = HumanBone.allCases.map(\.name)
    #expect(names.count == 55)
    #expect(Set(names).count == 55)
    #expect(names[0] == "Hips")
    #expect(names[10] == "Head")
    #expect(names[23] == "Jaw")
    #expect(names[24] == "LeftThumbProximal")
    #expect(names[53] == "RightLittleDistal")
    #expect(names.last == "UpperChest")
    #expect(HumanBone.allCases.filter(\.isFinger).count == 30)
    #expect(HumanBone.allCases.filter(\.isFace) == [.head, .leftEye, .rightEye])
}

/// 몸은 머리·눈 뒤, Val 앞: Root → HumanBone 순서. Head는 얼굴 것만, 몸 뼈는 위치 0이고 쿼터니언은 정규화한다
@Test func bodyMessagesComeBetweenFaceBonesAndValues() {
    let body = BodyPose(
        bones: [
            .leftIndexProximal: simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1)),
            .head: simd_quatf(angle: 1, axis: SIMD3(0, 1, 0)),
            .leftUpperArm: simd_quatf(ix: 0, iy: 0, iz: 2, r: 2),
            .spine: simd_quatf(angle: 0.1, axis: SIMD3(0, 0, 1)),
        ],
        root: simd_quatf(angle: 0.2, axis: SIMD3(0, 1, 0))
    )
    let messages = FaceLinkEncoder().messages(for: SyntheticFace.frame(at: 0), body: body, sequence: 1, time: 0)
    #expect(messages.count == 1 + 3 + 1 + 3 + 52 + 1)
    #expect(messages[1...3].map(boneName) == ["Head", "LeftEye", "RightEye"])
    #expect(messages[4].address == FaceLinkProtocol.Address.rootPosition)
    #expect(messages[4].arguments.first == .string("root"))
    #expect(messages[5...7].map(boneName) == ["Spine", "LeftUpperArm", "LeftIndexProximal"])
    #expect(messages[8].address == FaceLinkProtocol.Address.blendValue)
    #expect(messages.last == FaceLinkMessage.blendApply)
    for message in messages[4...7] {
        #expect(Array(message.arguments[1...3]) == [.float(0), .float(0), .float(0)])
        #expect(abs(quaternionLength(message) - 1) < 1e-5)
    }
}

/// 얼굴을 놓쳐도 몸은 보낸다: Frame → 몸 → Apply
@Test func lostFrameStillCarriesBody() {
    let messages = FaceLinkEncoder().messages(for: .lost, body: SyntheticFace.body(at: 0, hands: false), sequence: 2, time: 0)
    #expect(messages.first == FaceLinkMessage.frame(sequence: 2, time: 0, isTracked: false))
    #expect(messages.dropFirst().dropLast().map(boneName) == ["Spine", "LeftUpperArm", "LeftLowerArm"])
    #expect(messages.last == FaceLinkMessage.blendApply)
}

@Test func frameWithBodyAndHandsStaysWithin1400Bytes() {
    let datagrams = FaceLinkEncoder().datagrams(for: SyntheticFace.frame(at: 1), body: SyntheticFace.body(at: 1, hands: true), sequence: 1, time: 1)
    #expect(datagrams.count >= 3)
    #expect(datagrams.allSatisfy { $0.count <= FaceLinkProtocol.maxDatagramSize })
}

/// 3.8: 머리의 정수는 빅 엔디언, 표본은 리틀 엔디언
@Test func audioPacketBytes() {
    let packet = FaceLinkAudioPacket.encode(sequence: 0x0102_0304, sampleTime: 0x0102_0304_0506_0708, sampleRate: 48000, samples: [1, -2])
    var expected = Array("FLAU".utf8)
    expected += [1, 1, 1, 0] // 버전, 형식(PCM s16), 채널, 0
    expected += [1, 2, 3, 4] // 순번
    expected += [1, 2, 3, 4, 5, 6, 7, 8] // 표본 시각
    expected += [0, 0, 0xBB, 0x80] // 48000
    expected += [0, 2, 0, 0] // 표본 수, 0
    expected += [0x01, 0x00, 0xFE, 0xFF] // 1, −2
    #expect(packet == expected)
    #expect(FaceLinkAudioPacket.encode(sequence: 1, sampleTime: 0, sampleRate: 48000, channels: 2, samples: [1, 2, 3, 4])[24...25] == [0, 2])
}

private func audioHeader(_ packet: [UInt8]) -> (sequence: UInt32, sampleTime: UInt64, frames: Int, firstSample: Int16) {
    func number(_ range: Range<Int>) -> UInt64 {
        packet[range].reduce(0) { $0 << 8 | UInt64($1) }
    }
    let firstSample = Int16(bitPattern: UInt16(packet[28]) | UInt16(packet[29]) << 8)
    return (UInt32(number(8..<12)), number(12..<20), Int(number(24..<26)), firstSample)
}

/// 480표본씩 끊고 나머지는 다음 표본과 합친다. 순번은 1부터, 표본 시각은 첫 표본의 번호
@Test func audioPacketizerSplitsInto10msPackets() {
    var packetizer = AudioPacketizer()
    let samples = (0..<1440).map { Int16($0) }
    let first = packetizer.packets(appending: Array(samples[0..<1000]))
    #expect(first.count == 2)
    #expect(first.allSatisfy { $0.count == FaceLinkAudioPacket.headerSize + 960 })
    #expect(first.map { audioHeader($0).sequence } == [1, 2])
    #expect(first.map { audioHeader($0).sampleTime } == [0, 480])
    #expect(first.map { audioHeader($0).firstSample } == [0, 480])
    #expect(packetizer.packets(appending: Array(samples[1000..<1400])).isEmpty)
    let third = packetizer.packets(appending: Array(samples[1400..<1440]))
    #expect(third.count == 1)
    let header = audioHeader(third[0])
    #expect(header.sequence == 3)
    #expect(header.sampleTime == 960)
    #expect(header.frames == 480)
    #expect(header.firstSample == 960)

    // 순번은 넘치면 0부터
    var wrapping = AudioPacketizer(firstSequence: .max)
    #expect(wrapping.packets(appending: [Int16](repeating: 0, count: 960)).map { audioHeader($0).sequence } == [.max, 0])
}

/// 시각에 맞춰 표본 수를 낸다. 입을 다물면(시작) 조용하고, 다 벌리면(1초) 가장 크다
@Test func syntheticAudioFollowsTheMouth() {
    var audio = SyntheticAudio()
    let start = audio.samples(until: 0.01)
    #expect(start.count == 480)
    #expect(audio.samples(until: 0.01).isEmpty)
    #expect(audio.samples(until: 0.025).count == 720)
    #expect(start.map { abs(Int($0)) }.max()! < 100)
    _ = audio.samples(until: 1)
    let open = audio.samples(until: 1.01)
    #expect(open.map { abs(Int($0)) }.max()! > 12000)
}

/// 합성 몸의 방향 약속 (Unity 좌표, T 자세에서 왼팔은 −X): 위팔은 아래로, 아래팔은 앞으로, 손가락은 손바닥(아래) 쪽으로
@Test func syntheticBody() {
    let body = SyntheticFace.body(at: 0.7, hands: false)
    #expect(Set(body.bones.keys) == [.spine, .leftUpperArm, .leftLowerArm])
    let left = SIMD3<Float>(-1, 0, 0)
    #expect(body.bones[.leftUpperArm]!.act(left).y < -0.3)
    #expect(body.bones[.leftLowerArm]!.act(left).z > 0.1)

    let withHands = SyntheticFace.body(at: 0.7, hands: true)
    let fingers = withHands.bones.keys.filter(\.isFinger)
    #expect(fingers.count == 12)
    #expect(fingers.allSatisfy { $0.name.hasPrefix("Left") && !$0.name.contains("Thumb") })
    #expect(withHands.bones[.leftIndexProximal]!.act(left).y < 0)
    #expect(withHands.bones.values.allSatisfy { abs(simd_length($0.vector) - 1) < 1e-5 })
}
