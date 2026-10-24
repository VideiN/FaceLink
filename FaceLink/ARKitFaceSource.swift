import ARKit
import FaceLinkKit
import Synchronization
import UIKit

/// ARKit 얼굴 추적(TrueDepth) → FaceFrame (docs/face-link.md 4.1).
/// ARSession 콜백은 자기 큐에서 돈다 (그래서 nonisolated). 프레임은 받은 큐에서 바로 handler로 넘긴다
nonisolated final class ARKitFaceSource: NSObject, FaceFrameSource, ARSessionDelegate, @unchecked Sendable {
    enum State: Equatable, Sendable {
        case running
        /// 다른 앱이 카메라를 쓰거나 앱이 뒤로 감
        case interrupted
        case cameraDenied
        case failed(String)
    }

    /// TrueDepth 카메라가 있는 기기 (Face ID 아이폰). 시뮬레이터는 false
    static var isSupported: Bool {
        ARFaceTrackingConfiguration.isSupported
    }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "ARKitFaceSource", qos: .userInteractive)
    private let frameRate: Int
    private let handler: @Sendable (FaceFrame) -> Void
    private let onStateChange: @Sendable (State) -> Void
    /// 화면 방향. 머리 자세를 이 방향으로 본 카메라 기준으로 낸다 (메인에서 바꾸고 ARKit 큐에서 읽는다)
    private let orientation: Mutex<UIInterfaceOrientation>
    /// queue에서만: 마지막 프레임에 얼굴이 있었는지 (바뀔 때만 로그)
    private var wasTracked: Bool?

    init(
        frameRate: Int,
        orientation: UIInterfaceOrientation,
        handler: @escaping @Sendable (FaceFrame) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.frameRate = frameRate
        self.orientation = Mutex(orientation)
        self.handler = handler
        self.onStateChange = onStateChange
        super.init()
    }

    func setOrientation(_ value: UIInterfaceOrientation) {
        orientation.withLock { $0 = value }
    }

    func start() {
        session.delegate = self
        session.delegateQueue = queue
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        log("face: start ARKit face tracking (\(frameRate) Hz)")
        onStateChange(.running)
    }

    func stop() {
        session.pause()
        log("face: stop")
    }

    private func makeConfiguration() -> ARFaceTrackingConfiguration {
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = false
        // 30Hz면 카메라도 30fps로 돌려 발열·배터리를 줄인다 (더 빠르게 와도 보내는 쪽이 건너뛴다)
        if frameRate <= 30,
           let format = ARFaceTrackingConfiguration.supportedVideoFormats.first(where: { $0.framesPerSecond == 30 }) {
            configuration.videoFormat = format
        }
        return configuration
    }

    // MARK: - ARSessionDelegate (queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let anchor = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, anchor.isTracked else {
            trackingChanged(false)
            handler(.lost)
            return
        }
        trackingChanged(true)

        // 머리 자세는 카메라 기준 (3.2). 카메라 좌표는 화면 방향으로 돌려 본다:
        // 그래야 보정하기 전에도 머리를 세우면 기울기(roll)가 0이다. 정면 보정 뒤에는 이 차이가 지워진다
        let viewMatrix = frame.camera.viewMatrix(for: orientation.withLock { $0 })
        var shapes: [BlendShape: Float] = [:]
        for (location, value) in anchor.blendShapes {
            if let shape = BlendShape(arkitName: location.rawValue) {
                shapes[shape] = value.floatValue
            }
        }
        handler(FaceFrame(
            blendShapes: shapes,
            head: Pose(viewMatrix * anchor.transform),
            leftEye: Pose(anchor.leftEyeTransform).rotation,
            rightEye: Pose(anchor.rightEyeTransform).rotation
        ))
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        if let error = error as? ARError, error.code == .cameraUnauthorized {
            log("face: camera access denied")
            onStateChange(.cameraDenied)
        } else {
            log("face: failed \(error.localizedDescription)")
            onStateChange(.failed(error.localizedDescription))
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        log("face: interrupted")
        onStateChange(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        log("face: interruption ended, restart")
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        onStateChange(.running)
    }

    private func trackingChanged(_ tracked: Bool) {
        guard tracked != wasTracked else { return }
        wasTracked = tracked
        log(tracked ? "face: tracking" : "face: lost")
    }
}
