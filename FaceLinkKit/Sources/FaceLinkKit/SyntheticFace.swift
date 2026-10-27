import Foundation
import simd

/// 얼굴 프레임을 내는 것: ARKit 얼굴 추적 또는 시험용 합성 얼굴.
/// 프레임은 init에서 받은 handler로, 공급원 자기 스레드에서 넘긴다
public protocol FaceFrameSource: AnyObject, Sendable {
    func start()
    func stop()
}

/// 시험 송신용 합성 얼굴 (docs/face-link.md 4.1): 얼굴 없이 눈 깜빡임, 입 벌림, 머리 좌우를 만든다.
/// 시뮬레이터에서는 ARKit 얼굴 추적이 안 되므로 CI가 이것으로 보내기를 시험한다
public enum SyntheticFace {
    /// 머리 위치는 늘 같다 (카메라 앞 35cm). 그래서 정면 보정 뒤에는 위치가 0이 된다 (CI가 이것으로 보정을 확인한다)
    public static let headPosition = SIMD3<Float>(0, 0, -0.35)
    /// 몸은 이 속도로 (설계 4.6의 15~30Hz)
    public static let bodyFrameRate = 30

    /// 입: 2초 주기로 열고 닫기. 합성 소리도 이것을 따른다
    public static func jawOpen(at time: TimeInterval) -> Float {
        Float(0.5 - 0.5 * cos(time * .pi))
    }

    public static func frame(at time: TimeInterval) -> FaceFrame {
        // 3초마다 0.2초 동안 눈을 감았다 뜬다
        let blinkPhase = time.truncatingRemainder(dividingBy: 3)
        let blink = blinkPhase < 0.2 ? Float(sin(blinkPhase / 0.2 * .pi)) : 0
        // 머리: 4초 주기로 좌우 20도
        let yaw = Float(20 * Double.pi / 180 * sin(time * .pi / 2))
        // 눈은 머리 반대쪽으로 조금 (계속 정면을 보려는 것처럼)
        let eye = simd_quatf(angle: -yaw / 2, axis: SIMD3(0, 1, 0))
        return FaceFrame(
            blendShapes: [
                .eyeBlinkLeft: blink, .eyeBlinkRight: blink, .jawOpen: jawOpen(at: time), .mouthSmileLeft: 0.3, .mouthSmileRight: 0.3,
            ],
            head: Pose(position: headPosition, rotation: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))),
            leftEye: eye,
            rightEye: eye
        )
    }

    /// 몸 (v1.1): 몸을 좌우로 조금, 왼팔을 내렸다 들고 팔꿈치를 굽혔다 편다. hands면 왼손 네 손가락도 쥐었다 편다.
    /// Unity 좌표, 정규화 T 자세 기준: 왼팔은 −X쪽을 향하므로 +Z축으로 돌리면 아래로 내려가고,
    /// 아래팔은 +Y축으로 돌리면 앞(+Z)으로 굽고, 손가락(손바닥이 아래)은 +Z축으로 돌리면 손바닥 쪽으로 굽는다
    public static func body(at time: TimeInterval, hands: Bool) -> BodyPose {
        func radians(_ degrees: Double) -> Float { Float(degrees * .pi / 180) }
        let y = SIMD3<Float>(0, 1, 0)
        let z = SIMD3<Float>(0, 0, 1)
        var bones: [HumanBone: simd_quatf] = [
            .spine: simd_quatf(angle: radians(3 * sin(time * .pi / 2)), axis: z),
            // 3초 주기로 T 자세에서 20°~70° 내림
            .leftUpperArm: simd_quatf(angle: radians(45 + 25 * sin(time * 2 * .pi / 3)), axis: z),
            // 2초 주기로 10°~70° 굽힘
            .leftLowerArm: simd_quatf(angle: radians(40 + 30 * sin(time * .pi)), axis: y),
        ]
        if hands {
            // 2초 주기로 마디마다 0°~70°
            let curl = simd_quatf(angle: radians(35 + 35 * sin(time * .pi)), axis: z)
            for bone in HumanBone.allCases where bone.isFinger && bone.name.hasPrefix("Left") && !bone.name.contains("Thumb") {
                bones[bone] = curl
            }
        }
        return BodyPose(bones: bones)
    }
}

/// 시험 송신용 소리 (v1.1): 합성 얼굴의 입 벌림을 따라 커지고 작아지는 220 Hz 사인파, 48 kHz 모노 s16.
/// 받는 쪽에서 입 모양과 소리가 같이 움직이는지 귀로 볼 수 있다
public struct SyntheticAudio: Sendable {
    public static let frequency = 220.0
    /// 입을 다 벌렸을 때의 크기 (최대의 0.4배, 약 −8 dBFS)
    public static let peak = 0.4
    public let sampleRate: Double
    /// 지금까지 낸 표본 수
    public private(set) var sampleCount = 0

    public init(sampleRate: UInt32 = FaceLinkProtocol.audioSampleRate) {
        self.sampleRate = Double(sampleRate)
    }

    /// 시작부터 time초까지의 표본 중 아직 내지 않은 것. 타이머가 늦게 와도 표본 수는 시간에 맞는다
    public mutating func samples(until time: TimeInterval) -> [Int16] {
        let end = Int(time * sampleRate)
        guard end > sampleCount else { return [] }
        let samples = (sampleCount..<end).map { index -> Int16 in
            let t = Double(index) / sampleRate
            let amplitude = Self.peak * Double(SyntheticFace.jawOpen(at: t))
            return Int16(amplitude * sin(2 * .pi * Self.frequency * t) * Double(Int16.max))
        }
        sampleCount = end
        return samples
    }
}

/// 합성 얼굴을 정해진 속도로 낸다. body가 있으면 몸을 30Hz로(hands면 손가락도), audio가 있으면 소리를 10ms마다.
/// 몸은 같은 차례의 얼굴보다 먼저 넘겨 그 얼굴 프레임에 얹히게 한다. 상태는 queue에서만 만진다
public final class SyntheticFaceSource: FaceFrameSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyntheticFaceSource", qos: .userInteractive)
    private let frameRate: Int
    private let hands: Bool
    private let handler: @Sendable (FaceFrame) -> Void
    private let bodyHandler: (@Sendable (BodyPose) -> Void)?
    private let audioHandler: (@Sendable ([Int16]) -> Void)?
    private var timer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var startTime: TimeInterval = 0
    private var bodyLimiter = FrameRateLimiter(frameRate: SyntheticFace.bodyFrameRate)
    private var audio = SyntheticAudio()

    public init(
        frameRate: Int,
        hands: Bool = false,
        handler: @escaping @Sendable (FaceFrame) -> Void,
        body: (@Sendable (BodyPose) -> Void)? = nil,
        audio: (@Sendable ([Int16]) -> Void)? = nil
    ) {
        self.frameRate = frameRate
        self.hands = hands
        self.handler = handler
        bodyHandler = body
        audioHandler = audio
    }

    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            self.startTime = Self.now
            self.bodyLimiter = FrameRateLimiter(frameRate: SyntheticFace.bodyFrameRate)
            self.audio = SyntheticAudio()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1 / Double(self.frameRate), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer

            if self.audioHandler != nil {
                let audioTimer = DispatchSource.makeTimerSource(queue: self.queue)
                audioTimer.schedule(deadline: .now(), repeating: 0.01, leeway: .milliseconds(1))
                audioTimer.setEventHandler { [weak self] in self?.audioTick() }
                audioTimer.resume()
                self.audioTimer = audioTimer
            }
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.audioTimer?.cancel()
            self.audioTimer = nil
        }
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func tick() {
        let time = Self.now - startTime
        if let bodyHandler, bodyLimiter.shouldSend(at: time) {
            bodyHandler(SyntheticFace.body(at: time, hands: hands))
        }
        handler(SyntheticFace.frame(at: time))
    }

    private func audioTick() {
        guard let audioHandler else { return }
        let samples = audio.samples(until: Self.now - startTime)
        if !samples.isEmpty {
            audioHandler(samples)
        }
    }
}
