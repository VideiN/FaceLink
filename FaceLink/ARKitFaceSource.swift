import ARKit
import AVFoundation
import CoreMedia
import FaceLinkKit
import Synchronization
import UIKit

/// ARKit 얼굴 추적(TrueDepth) → FaceFrame (docs/face-link.md 4.1).
/// 소리를 켜면 같은 세션의 마이크 표본도 받아 48 kHz 모노 s16으로 넘긴다 (4.7, `providesAudioData`).
/// ARSession 콜백은 자기 큐에서 돈다 (그래서 nonisolated). 프레임은 받은 큐에서 바로 handler로 넘긴다
nonisolated final class ARKitFaceSource: NSObject, FaceFrameSource, ARSessionDelegate, @unchecked Sendable {
    enum State: Equatable, Sendable {
        case running
        /// 다른 앱이 카메라를 쓰거나 앱이 뒤로 감
        case interrupted
        case cameraDenied
        /// 마이크 권한이 없어 소리 없이 얼굴만 보낸다
        case microphoneDenied
        case failed(String)
    }

    /// 소리를 어디서 받나
    private nonisolated enum AudioPath {
        case off
        /// 얼굴 추적과 같은 ARKit 세션 (얼굴 프레임과 같은 시계라 입 모양과 맞추기 쉽다)
        case arkit
        /// ARKit이 소리를 주지 않을 때: AVAudioEngine 입력 탭
        case engine
    }

    /// TrueDepth 카메라가 있는 기기 (Face ID 아이폰). 시뮬레이터는 false
    static var isSupported: Bool {
        ARFaceTrackingConfiguration.isSupported
    }

    /// 이만큼(초) 지나도 ARKit이 소리를 주지 않으면 AVAudioEngine으로 바꾼다
    static let audioTimeout: TimeInterval = 3

    private let session = ARSession()
    private let queue = DispatchQueue(label: "ARKitFaceSource", qos: .userInteractive)
    private let frameRate: Int
    private let handler: @Sendable (FaceFrame) -> Void
    private let audioHandler: (@Sendable ([Int16]) -> Void)?
    private let onStateChange: @Sendable (State) -> Void
    /// 화면 방향. 머리 자세를 이 방향으로 본 카메라 기준으로 낸다 (메인에서 바꾸고 ARKit 큐에서 읽는다)
    private let orientation: Mutex<UIInterfaceOrientation>
    /// queue에서만: 마지막 프레임에 얼굴이 있었는지 (바뀔 때만 로그)
    private var wasTracked: Bool?
    /// queue에서만 (start는 큐가 돌기 전)
    private var audioPath: AudioPath
    private var arkitAudioBuffers = 0
    private let arkitConverter = MicrophoneConverter()
    private var engine: AVAudioEngine?
    /// 엔진의 탭 스레드에서만
    private let engineConverter = MicrophoneConverter()

    init(
        frameRate: Int,
        orientation: UIInterfaceOrientation,
        handler: @escaping @Sendable (FaceFrame) -> Void,
        audio: (@Sendable ([Int16]) -> Void)? = nil,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.frameRate = frameRate
        self.orientation = Mutex(orientation)
        self.handler = handler
        audioHandler = audio
        audioPath = audio == nil ? .off : .arkit
        self.onStateChange = onStateChange
        super.init()
    }

    func setOrientation(_ value: UIInterfaceOrientation) {
        orientation.withLock { $0 = value }
    }

    func start() {
        session.delegate = self
        session.delegateQueue = queue
        let audio = audioHandler != nil
        session.run(makeConfiguration(audio: audio), options: [.resetTracking, .removeExistingAnchors])
        log("face: start ARKit face tracking (\(frameRate) Hz\(audio ? ", audio" : ""))")
        onStateChange(.running)
        if audio {
            queue.asyncAfter(deadline: .now() + Self.audioTimeout) { [weak self] in
                self?.checkARKitAudio()
            }
        }
    }

    func stop() {
        session.pause()
        queue.async { self.stopAudio() }
        log("face: stop")
    }

    private func makeConfiguration(audio: Bool) -> ARFaceTrackingConfiguration {
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = false
        configuration.providesAudioData = audio
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

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        guard case .arkit = audioPath else { return }
        arkitAudioBuffers += 1
        deliverAudio(from: "ARKit", converter: arkitConverter, frames: CMSampleBufferGetNumSamples(audioSampleBuffer)) {
            try $0.convert(audioSampleBuffer)
        }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        if let error = error as? ARError, error.code == .cameraUnauthorized {
            log("face: camera access denied")
            onStateChange(.cameraDenied)
        } else if let error = error as? ARError, error.code == .microphoneUnauthorized {
            // 얼굴은 계속 보낸다
            log("face: microphone access denied, restart without audio")
            audioPath = .off
            session.run(makeConfiguration(audio: false))
            onStateChange(.microphoneDenied)
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
        session.run(makeConfiguration(audio: isARKitAudio), options: [.resetTracking, .removeExistingAnchors])
        onStateChange(.running)
        if let engine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                log("audio: AVAudioEngine restart failed \(error.localizedDescription)")
            }
        }
    }

    private func trackingChanged(_ tracked: Bool) {
        guard tracked != wasTracked else { return }
        wasTracked = tracked
        log(tracked ? "face: tracking" : "face: lost")
    }

    // MARK: - 소리 (queue, 탭 스레드)

    private var isARKitAudio: Bool {
        switch audioPath {
        case .arkit: true
        case .off, .engine: false
        }
    }

    /// 형식이 처음 오거나 바뀌면 ARKit·엔진이 준 형식을 로그에 남긴다 (실기기에서 무엇이 오는지 보려고)
    private func deliverAudio(
        from source: String, converter: MicrophoneConverter, frames: Int, convert: (MicrophoneConverter) throws -> [Int16]
    ) {
        let format = converter.inputFormat
        do {
            let samples = try convert(converter)
            if let input = converter.inputFormat, input != format {
                log("audio: \(source) \(input.summary), \(frames) frames per buffer → \(converter.outputFormat.summary)")
            }
            audioHandler?(samples)
        } catch {
            if converter.failures == 1 || converter.failures % 100 == 0 {
                log("audio: \(source) \(error) (\(converter.failures) times)")
            }
        }
    }

    private func checkARKitAudio() {
        guard isARKitAudio else { return }
        guard arkitAudioBuffers == 0 else { return }
        log("audio: no audio from ARKit for \(Int(Self.audioTimeout)) s, switch to AVAudioEngine")
        audioPath = .engine
        session.run(makeConfiguration(audio: false))
        startEngine()
    }

    private func startEngine() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                log("audio: AVAudioEngine has no input (\(format.summary))")
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.deliverAudio(from: "AVAudioEngine", converter: self.engineConverter, frames: Int(buffer.frameLength)) {
                    try $0.convert(buffer)
                }
            }
            try engine.start()
            self.engine = engine
        } catch {
            log("audio: AVAudioEngine failed \(error.localizedDescription)")
        }
    }

    private func stopAudio() {
        audioPath = .off
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
