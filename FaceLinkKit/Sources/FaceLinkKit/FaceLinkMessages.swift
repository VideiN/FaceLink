import Foundation
import simd

/// FaceLink v1 메시지 만들기 (docs/face-link.md 3.2, 3.3, 3.5)
public enum FaceLinkMessage {
    /// 보내는 동안 1초마다. 번들에 넣지 않고 따로 보낸다. 여섯째 인자는 v1.1의 기능 (v1 받는 쪽은 무시한다)
    public static func hello(
        deviceName: String, appVersion: String, sessionID: String, token: String, features: Set<FaceLinkFeature> = [.face]
    ) -> OSCMessage {
        OSCMessage(FaceLinkProtocol.Address.hello, [
            .string(FaceLinkProtocol.version), .string(deviceName), .string(appVersion), .string(sessionID), .string(token),
            .string(FaceLinkFeature.list(features)),
        ])
    }

    /// 프레임마다 맨 앞. time은 세션 시작부터 초
    public static func frame(sequence: Int32, time: Float, isTracked: Bool) -> OSCMessage {
        OSCMessage(FaceLinkProtocol.Address.frame, [.int(sequence), .float(time), .int(isTracked ? 1 : 0)])
    }

    /// 위치·회전은 VMC(Unity) 좌표
    public static func bone(_ name: String, position: SIMD3<Float>, rotation: simd_quatf) -> OSCMessage {
        OSCMessage(FaceLinkProtocol.Address.bonePosition, [
            .string(name),
            .float(position.x), .float(position.y), .float(position.z),
            .float(rotation.imag.x), .float(rotation.imag.y), .float(rotation.imag.z), .float(rotation.real),
        ])
    }

    /// v1.1: 몸 전체 방향. 위치는 0 (받는 쪽은 회전만 쓴다)
    public static func root(rotation: simd_quatf) -> OSCMessage {
        OSCMessage(FaceLinkProtocol.Address.rootPosition, [
            .string("root"),
            .float(0), .float(0), .float(0),
            .float(rotation.imag.x), .float(rotation.imag.y), .float(rotation.imag.z), .float(rotation.real),
        ])
    }

    public static func blendValue(_ shape: BlendShape, _ value: Float) -> OSCMessage {
        OSCMessage(FaceLinkProtocol.Address.blendValue, [.string(shape.name), .float(value)])
    }

    public static let blendApply = OSCMessage(FaceLinkProtocol.Address.blendApply)

    /// 받는 쪽 → 보내는 쪽 (이 앱은 받기만 한다. 시험에서 받는 쪽 흉내에 쓴다)
    public static func ack(lastSequence: Int32, receiverFPS: Float, receiverName: String) -> OSCMessage {
        OSCMessage(FaceLinkProtocol.Address.ack, [.int(lastSequence), .float(receiverFPS), .string(receiverName)])
    }

    public static let calibrate = OSCMessage(FaceLinkProtocol.Address.calibrate)
}

/// 얼굴 한 프레임 → 데이터그램들 (docs/face-link.md 3.1)
public struct FaceLinkEncoder: Sendable {
    /// `/VMC/Ext/Bone/Pos`로 눈 방향을 보낼지 (설정 "눈 보내기")
    public var sendEyes: Bool
    /// false면 머리 위치를 0으로 보낸다 (설정 "머리 위치 보내기")
    public var sendHeadPosition: Bool
    public var maxDatagramSize: Int

    public init(sendEyes: Bool = true, sendHeadPosition: Bool = true, maxDatagramSize: Int = FaceLinkProtocol.maxDatagramSize) {
        self.sendEyes = sendEyes
        self.sendHeadPosition = sendHeadPosition
        self.maxDatagramSize = maxDatagramSize
    }

    /// Frame → Bone(머리, 눈) → 몸(v1.1, 있으면) → Val ×52 → Apply. 얼굴을 놓친 프레임은 머리·눈·Val을 뺀다 (몸은 보낸다).
    /// frame.head는 정면 보정까지 끝난 ARKit 좌표 값이고, 여기서 VMC(Unity) 좌표로 바꾼다. 몸은 처음부터 Unity 좌표다
    public func messages(for frame: FaceFrame, body: BodyPose? = nil, sequence: Int32, time: Float) -> [OSCMessage] {
        var messages = [FaceLinkMessage.frame(sequence: sequence, time: time, isTracked: frame.isTracked)]
        if frame.isTracked {
            let position = sendHeadPosition ? UnityCoordinates.position(frame.head.position) : .zero
            messages.append(FaceLinkMessage.bone("Head", position: position, rotation: UnityCoordinates.rotation(frame.head.rotation)))
            if sendEyes, let leftEye = frame.leftEye, let rightEye = frame.rightEye {
                messages.append(FaceLinkMessage.bone("LeftEye", position: .zero, rotation: UnityCoordinates.rotation(leftEye)))
                messages.append(FaceLinkMessage.bone("RightEye", position: .zero, rotation: UnityCoordinates.rotation(rightEye)))
            }
        }
        if let body {
            messages += Self.bodyMessages(body)
        }
        if frame.isTracked {
            for shape in BlendShape.allCases {
                let value = frame.blendShapes[shape] ?? 0
                messages.append(FaceLinkMessage.blendValue(shape, min(max(value, 0), 1)))
            }
        }
        messages.append(FaceLinkMessage.blendApply)
        return messages
    }

    /// 번들 여러 개로 나눈 데이터그램. 하나가 maxDatagramSize 바이트를 넘지 않는다
    public func datagrams(for frame: FaceFrame, body: BodyPose? = nil, sequence: Int32, time: Float) -> [[UInt8]] {
        OSCBundle.pack(messages(for: frame, body: body, sequence: sequence, time: time), maxSize: maxDatagramSize)
    }

    /// 몸 (v1.1, 3.2): Root, 그리고 HumanBone 순서로 뼈마다 Bone/Pos (위치 0).
    /// Head·눈은 얼굴이 보내므로 뺀다 (한 프레임에 같은 뼈가 두 번 가지 않게)
    static func bodyMessages(_ body: BodyPose) -> [OSCMessage] {
        var messages: [OSCMessage] = []
        if let root = body.root {
            messages.append(FaceLinkMessage.root(rotation: root.normalized))
        }
        for bone in HumanBone.allCases where !bone.isFace {
            if let rotation = body.bones[bone] {
                messages.append(FaceLinkMessage.bone(bone.name, position: .zero, rotation: rotation.normalized))
            }
        }
        return messages
    }
}

/// 받는 쪽이 1초마다 보내는 확인 (3.5)
public struct FaceLinkAck: Equatable, Sendable {
    public var lastSequence: Int32
    public var receiverFPS: Float
    public var receiverName: String

    public init(lastSequence: Int32, receiverFPS: Float, receiverName: String) {
        self.lastSequence = lastSequence
        self.receiverFPS = receiverFPS
        self.receiverName = receiverName
    }
}

/// 받는 쪽 → 보내는 쪽 메시지 (3.5)
public enum FaceLinkInbound: Equatable, Sendable {
    case ack(FaceLinkAck)
    case calibrate

    /// 모르는 주소나 형식이 다른 메시지는 nil. 남는 인자는 무시한다 (VMC 규칙)
    public init?(_ message: OSCMessage) {
        switch message.address {
        case FaceLinkProtocol.Address.ack:
            let arguments = message.arguments
            guard arguments.count >= 3,
                  case .int(let sequence) = arguments[0],
                  case .float(let fps) = arguments[1],
                  case .string(let name) = arguments[2]
            else { return nil }
            self = .ack(FaceLinkAck(lastSequence: sequence, receiverFPS: fps, receiverName: name))
        case FaceLinkProtocol.Address.calibrate:
            self = .calibrate
        default:
            return nil
        }
    }
}

/// 보내는 쪽의 세션 (3.3): 보내기를 시작할 때마다 새 ID, 순번은 1씩 늘고 2³¹−1 다음은 0
public struct FaceLinkSession: Sendable {
    public let id: String
    /// 세션을 시작한 시각 (단조 시계, 초)
    public let startTime: TimeInterval
    public private(set) var nextSequence: Int32

    public init(id: String = UUID().uuidString, startTime: TimeInterval, firstSequence: Int32 = 1) {
        self.id = id
        self.startTime = startTime
        nextSequence = firstSequence
    }

    public mutating func takeSequence() -> Int32 {
        let sequence = nextSequence
        nextSequence = sequence == .max ? 0 : sequence + 1
        return sequence
    }

    /// `/FaceLink/Frame`의 보낸 시각
    public func time(at now: TimeInterval) -> Float {
        Float(now - startTime)
    }
}

/// 보낸 순번과 시각을 기억해 두고 Ack의 순번으로 왕복 시간을 잰다 (3.5의 "대략 지연")
public struct RoundTripTracker: Sendable {
    private struct Entry: Sendable {
        let sequence: Int32
        let time: TimeInterval
    }

    private var entries: [Entry?]

    /// 60Hz로 8초 남짓
    public init(capacity: Int = 512) {
        entries = Array(repeating: nil, count: capacity)
    }

    public mutating func recordSent(_ sequence: Int32, at time: TimeInterval) {
        entries[slot(sequence)] = Entry(sequence: sequence, time: time)
    }

    /// 너무 오래되어 잊은 순번이면 nil
    public func roundTrip(forAck sequence: Int32, receivedAt now: TimeInterval) -> TimeInterval? {
        guard let entry = entries[slot(sequence)], entry.sequence == sequence else { return nil }
        return now - entry.time
    }

    private func slot(_ sequence: Int32) -> Int {
        Int(UInt32(bitPattern: sequence) % UInt32(entries.count))
    }
}
