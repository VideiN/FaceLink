import FaceLinkKit
import Foundation
import Observation
import UIKit

/// 앱 상태: 보낼 곳, 보내기, 화면에 보일 상태
@Observable
final class AppModel {
    /// 지금 고른 보낼 곳. 처음에는 마지막으로 연결한 곳
    var target: FaceLinkTarget?
    /// 마지막으로 보내기를 시작한 곳 (docs/face-link.md 3.4: 보내는 쪽은 마지막 대상을 기억한다)
    private(set) var lastTarget: FaceLinkTarget?
    var frameRate = 60
    private(set) var isSending = false
    private(set) var status = FaceLinkSender.Status()
    /// Bonjour로 찾은 받는 쪽
    private(set) var services: [FaceLinkBrowser.Service] = []
    private(set) var browseProblem: NetworkProblem?

    @ObservationIgnored private var sender: FaceLinkSender?
    @ObservationIgnored private var source: (any FaceFrameSource)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var browser: FaceLinkBrowser?
    private let defaults: UserDefaults

    private static let lastTargetKey = "lastTarget"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.lastTargetKey) {
            lastTarget = try? JSONDecoder().decode(FaceLinkTarget.self, from: data)
        }
        target = lastTarget
    }

    func choose(_ target: FaceLinkTarget) {
        self.target = target
        log("target: \(target.addressDescription) (\(target.name))\(target.token.isEmpty ? "" : " with token")")
    }

    /// 얼굴 없이 합성 값을 보낸다 (docs/face-link.md 4.1 시험 송신 모드)
    func startTestSend() {
        guard let target, !isSending else { return }
        let configuration = FaceLinkSender.Configuration(
            target: target,
            deviceName: UIDevice.current.name,
            appVersion: BuildInfo.current.version,
            frameRate: frameRate
        )
        let sender = FaceLinkSender(configuration: configuration) { event in
            log("sender: \(event)")
        }
        let source = SyntheticFaceSource(frameRate: frameRate) { [sender] frame in
            sender.send(frame)
        }
        self.sender = sender
        self.source = source
        isSending = true
        sender.start()
        source.start()
        remember(target)
        log("sender: start test send to \(target.addressDescription) (\(target.name)) at \(frameRate) Hz")

        // 화면의 상태는 1초마다 고친다 (프레임마다 고치면 메인 스레드가 바쁘다)
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let sender = self.sender else { return }
                let status = sender.currentStatus
                self.status = status
                log("sender: stats \(status.sendFPS) fps, sent \(status.framesSent), responding \(status.isResponding)")
            }
        }
    }

    func stop() {
        guard isSending else { return }
        statusTask?.cancel()
        source?.stop()
        sender?.stop()
        statusTask = nil
        source = nil
        sender = nil
        isSending = false
        status = FaceLinkSender.Status()
        log("sender: stopped")
    }

    /// 정면 맞추기: 지금 머리 자세를 기준으로
    func calibrate() {
        sender?.calibrate()
        log("sender: calibrate requested in app")
    }

    private func remember(_ target: FaceLinkTarget) {
        lastTarget = target
        if let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: Self.lastTargetKey)
        }
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
///   -autotest-send <주소>   시험 송신을 바로 시작한다. 주소는 facelink:// QR 주소 또는 "IP:포트"
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
        startTestSend()
    }
}
