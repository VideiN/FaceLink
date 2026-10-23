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

    public static func frame(at time: TimeInterval) -> FaceFrame {
        // 3초마다 0.2초 동안 눈을 감았다 뜬다
        let blinkPhase = time.truncatingRemainder(dividingBy: 3)
        let blink = blinkPhase < 0.2 ? Float(sin(blinkPhase / 0.2 * .pi)) : 0
        // 입: 2초 주기로 열고 닫기
        let jaw = Float(0.5 - 0.5 * cos(time * .pi))
        // 머리: 4초 주기로 좌우 20도
        let yaw = Float(20 * Double.pi / 180 * sin(time * .pi / 2))
        // 눈은 머리 반대쪽으로 조금 (계속 정면을 보려는 것처럼)
        let eye = simd_quatf(angle: -yaw / 2, axis: SIMD3(0, 1, 0))
        return FaceFrame(
            blendShapes: [.eyeBlinkLeft: blink, .eyeBlinkRight: blink, .jawOpen: jaw, .mouthSmileLeft: 0.3, .mouthSmileRight: 0.3],
            head: Pose(position: headPosition, rotation: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))),
            leftEye: eye,
            rightEye: eye
        )
    }
}

/// 합성 얼굴을 정해진 속도로 낸다. 상태는 queue에서만 만진다
public final class SyntheticFaceSource: FaceFrameSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyntheticFaceSource", qos: .userInteractive)
    private let frameRate: Int
    private let handler: @Sendable (FaceFrame) -> Void
    private var timer: DispatchSourceTimer?

    public init(frameRate: Int, handler: @escaping @Sendable (FaceFrame) -> Void) {
        self.frameRate = frameRate
        self.handler = handler
    }

    public func start() {
        queue.async {
            guard self.timer == nil else { return }
            let startTime = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1 / Double(self.frameRate), leeway: .milliseconds(1))
            timer.setEventHandler { [handler = self.handler] in
                handler(SyntheticFace.frame(at: ProcessInfo.processInfo.systemUptime - startTime))
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }
}
