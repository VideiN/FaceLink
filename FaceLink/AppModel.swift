import FaceLinkKit
import Foundation
import Observation
import UIKit

/// 무엇을 보내나
enum SendMode: String, Sendable {
    /// ARKit 얼굴 추적 (실기기)
    case face
    /// 얼굴 없이 합성 값 (docs/face-link.md 4.1 시험 송신 모드. 시뮬레이터·CI)
    case test
}

/// 설정 "몸" (docs/face-link.md 4.6): 얼굴만, 상체, 상체+손
enum BodyMode: String, CaseIterable, Sendable {
    case off
    case upperBody
    case upperBodyAndHands

    var title: String {
        switch self {
        case .off: "얼굴만"
        case .upperBody: "상체"
        case .upperBodyAndHands: "상체+손"
        }
    }

    var features: Set<FaceLinkFeature> {
        switch self {
        case .off: []
        case .upperBody: [.body]
        case .upperBodyAndHands: [.body, .hands]
        }
    }
}

/// 앱 상태: 보낼 곳, 보내기, 설정, 화면에 보일 상태
@Observable
final class AppModel {
    /// 지금 고른 보낼 곳. 처음에는 마지막으로 연결한 곳
    var target: FaceLinkTarget?
    /// 마지막으로 보내기를 시작한 곳 (docs/face-link.md 3.4: 보내는 쪽은 마지막 대상을 기억한다)
    private(set) var lastTarget: FaceLinkTarget?

    // 설정 (4.1). 보내는 동안에는 바꾸지 않는다
    var frameRate: Int {
        didSet { defaults.set(frameRate, forKey: Keys.frameRate) }
    }
    var sendEyes: Bool {
        didSet { defaults.set(sendEyes, forKey: Keys.sendEyes) }
    }
    var sendHeadPosition: Bool {
        didSet { defaults.set(sendHeadPosition, forKey: Keys.sendHeadPosition) }
    }
    /// v1.1 몸·소리. 지금은 시험 송신만 따른다 (얼굴 추적의 소리는 계획 8단계, 몸은 9단계)
    var bodyMode: BodyMode {
        didSet { defaults.set(bodyMode.rawValue, forKey: Keys.bodyMode) }
    }
    var sendAudio: Bool {
        didSet { defaults.set(sendAudio, forKey: Keys.sendAudio) }
    }

    private(set) var mode: SendMode?
    /// 지금 보내는 것 (Hello의 기능)
    private(set) var features: Set<FaceLinkFeature> = []
    var isSending: Bool { mode != nil }
    private(set) var status = FaceLinkSender.Status()
    /// ARKit 얼굴 추적의 상태 (얼굴 추적으로 보낼 때)
    private(set) var faceState: ARKitFaceSource.State?
    /// 정면 맞추기까지 남은 초 (누르고 정면을 볼 시간을 준다)
    private(set) var calibrationCountdown: Int?
    /// Bonjour로 찾은 받는 쪽
    private(set) var services: [FaceLinkBrowser.Service] = []
    private(set) var browseProblem: NetworkProblem?

    static var isFaceTrackingSupported: Bool { ARKitFaceSource.isSupported }
    /// 정면 맞추기를 누르고 실제로 맞추기까지 (초)
    static let calibrationDelay = 3

    @ObservationIgnored private var sender: FaceLinkSender?
    @ObservationIgnored private var source: (any FaceFrameSource)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var browser: FaceLinkBrowser?
    private let defaults: UserDefaults

    private enum Keys {
        static let lastTarget = "lastTarget"
        static let frameRate = "frameRate"
        static let sendEyes = "sendEyes"
        static let sendHeadPosition = "sendHeadPosition"
        static let bodyMode = "bodyMode"
        static let sendAudio = "sendAudio"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        frameRate = defaults.object(forKey: Keys.frameRate) as? Int ?? 60
        sendEyes = defaults.object(forKey: Keys.sendEyes) as? Bool ?? true
        sendHeadPosition = defaults.object(forKey: Keys.sendHeadPosition) as? Bool ?? true
        bodyMode = defaults.string(forKey: Keys.bodyMode).flatMap(BodyMode.init(rawValue:)) ?? .off
        sendAudio = defaults.object(forKey: Keys.sendAudio) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.lastTarget) {
            lastTarget = try? JSONDecoder().decode(FaceLinkTarget.self, from: data)
        }
        target = lastTarget
    }

    func choose(_ target: FaceLinkTarget) {
        self.target = target
        log("target: \(target.addressDescription) (\(target.name))\(target.token.isEmpty ? "" : " with token")")
    }

    // MARK: - 보내기

    func start(_ mode: SendMode) {
        guard let target, !isSending else { return }
        if mode == .face && !Self.isFaceTrackingSupported {
            log("face: not supported on this device")
            return
        }
        let features = sendFeatures(for: mode)
        let configuration = FaceLinkSender.Configuration(
            target: target,
            deviceName: UIDevice.current.name,
            appVersion: BuildInfo.current.version,
            frameRate: frameRate,
            sendEyes: sendEyes,
            sendHeadPosition: sendHeadPosition,
            features: features
        )
        let sender = FaceLinkSender(configuration: configuration) { event in
            log("sender: \(event)")
        }
        let handler: @Sendable (FaceFrame) -> Void = { [sender] frame in
            sender.send(frame)
        }
        let source: any FaceFrameSource
        switch mode {
        case .test:
            // 삼항 연산자 안의 클로저는 @Sendable로 추론되지 않아 if로 넣는다
            var body: (@Sendable (BodyPose) -> Void)?
            var audio: (@Sendable ([Int16]) -> Void)?
            if features.contains(.body) {
                body = { [sender] pose in sender.sendBody(pose) }
            }
            if features.contains(.audio) {
                audio = { [sender] samples in sender.sendAudio(samples) }
            }
            source = SyntheticFaceSource(frameRate: frameRate, hands: features.contains(.hands), handler: handler, body: body, audio: audio)
        case .face:
            source = ARKitFaceSource(frameRate: frameRate, orientation: interfaceOrientation, handler: handler) { [weak self] state in
                guard let self else { return }
                Task { @MainActor in self.faceState = state }
            }
        }
        self.sender = sender
        self.source = source
        self.mode = mode
        self.features = features
        faceState = nil
        sender.start()
        source.start()
        remember(target)
        // 화면이 꺼지면 앱이 뒤로 가고 ARKit이 멈춘다 (4.1)
        UIApplication.shared.isIdleTimerDisabled = true
        log("sender: start \(mode.rawValue) to \(target.addressDescription) (\(target.name)) at \(frameRate) Hz, eyes \(sendEyes), head position \(sendHeadPosition), features \(FaceLinkFeature.list(features))")

        // 화면의 상태는 1초마다 고친다 (프레임마다 고치면 메인 스레드가 바쁘다)
        statusTask = Task { [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let sender = self.sender else { return }
                let status = sender.currentStatus
                self.status = status
                // 화면을 돌렸으면 얼굴 추적에도 알린다
                (self.source as? ARKitFaceSource)?.setOrientation(self.interfaceOrientation)
                seconds += 1
                if seconds % 5 == 0 {
                    log("sender: stats \(status.sendFPS) fps, sent \(status.framesSent), tracking \(status.isTracking), responding \(status.isResponding), body \(status.bodyFPS) fps, audio \(status.audioPacketsPerSecond) packets/s")
                }
            }
        }
    }

    func stop() {
        guard isSending else { return }
        statusTask?.cancel()
        calibrationTask?.cancel()
        source?.stop()
        sender?.stop()
        statusTask = nil
        calibrationTask = nil
        calibrationCountdown = nil
        source = nil
        sender = nil
        mode = nil
        features = []
        faceState = nil
        status = FaceLinkSender.Status()
        UIApplication.shared.isIdleTimerDisabled = false
        log("sender: stopped")
    }

    /// 설정의 몸·소리를 따른 기능. 얼굴 추적은 아직 얼굴만 보낸다 (소리는 계획 8단계, 몸은 9단계)
    private func sendFeatures(for mode: SendMode) -> Set<FaceLinkFeature> {
        var features: Set<FaceLinkFeature> = [.face]
        if mode == .test {
            features.formUnion(bodyMode.features)
            if sendAudio {
                features.insert(.audio)
            }
        }
        return features
    }

    /// 정면 맞추기: 몇 초 뒤의 머리 자세를 기준으로 (누른 뒤 정면을 볼 시간을 준다).
    /// 아이패드의 "정면 맞추기"(/FaceLink/Calibrate)는 기다리지 않고 바로 맞춘다
    func calibrate(after delay: Int = AppModel.calibrationDelay) {
        guard isSending else { return }
        calibrationTask?.cancel()
        calibrationTask = Task { [weak self] in
            for remaining in stride(from: delay, to: 0, by: -1) {
                self?.calibrationCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.calibrationCountdown = nil
            self.sender?.calibrate()
            log("sender: calibrate requested in app")
        }
    }

    private func remember(_ target: FaceLinkTarget) {
        lastTarget = target
        if let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: Keys.lastTarget)
        }
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.effectiveGeometry.interfaceOrientation ?? .portrait
    }

    // MARK: - Bonjour

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = FaceLinkBrowser(
            onChange: { [weak self] services in
                guard let self else { return }
                Task { @MainActor in self.servicesChanged(services) }
            },
            onProblem: { [weak self] problem in
                guard let self else { return }
                Task { @MainActor in self.browseProblemChanged(problem) }
            }
        )
        self.browser = browser
        browser.start()
        log("browse: start")
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
        services = []
        browseProblem = nil
    }

    private func servicesChanged(_ services: [FaceLinkBrowser.Service]) {
        let known = Set(self.services.map(\.id))
        for service in services where !known.contains(service.id) {
            log("browse: found \(service.displayName) (service \(service.serviceName), v\(service.version ?? "?"))")
        }
        self.services = services
    }

    private func browseProblemChanged(_ problem: NetworkProblem?) {
        if let problem {
            log("browse: problem \(problem)")
        }
        browseProblem = problem
    }
}

/// CI가 앱을 띄울 때 주는 실행 인자 (scripts/ci-run-simulator.sh)
///   -autotest-send <주소>   시험 송신을 바로 시작한다 (몸·손가락·소리를 모두 켜고). 주소는 facelink:// QR 주소 또는 "IP:포트"
///   -autotest-browse        Bonjour 찾기를 켠다 (찾은 것을 로그로)
extension AppModel {
    func runAutoTest(arguments: [String]) {
        if arguments.contains("-autotest-browse") {
            startBrowsing()
        }
        guard let index = arguments.firstIndex(of: "-autotest-send"), index + 1 < arguments.count else { return }
        let value = arguments[index + 1]
        guard let target = FaceLinkTarget(urlOrAddress: value) else {
            log("autotest: bad target \(value)")
            return
        }
        log("autotest: send to \(value)")
        choose(target)
        bodyMode = .upperBodyAndHands
        sendAudio = true
        start(.test)
    }
}
