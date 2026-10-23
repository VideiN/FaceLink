import FaceLinkKit
import Foundation
import Observation
import UIKit

/// 앱 상태: 보낼 곳, 보내기, 화면에 보일 상태
@Observable
final class AppModel {
    var target: FaceLinkTarget?
    var frameRate = 60
    private(set) var isSending = false
    private(set) var status = FaceLinkSender.Status()

    @ObservationIgnored private var sender: FaceLinkSender?
    @ObservationIgnored private var source: (any FaceFrameSource)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

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
}

/// CI가 앱을 띄울 때 주는 실행 인자 (scripts/ci-run-simulator.sh)
///   -autotest-send <주소>   시험 송신을 바로 시작한다. 주소는 "IP:포트"
extension AppModel {
    func runAutoTest(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-autotest-send"), index + 1 < arguments.count else { return }
        let value = arguments[index + 1]
        guard let target = FaceLinkTarget(address: value) else {
            log("autotest: bad target \(value)")
            return
        }
        log("autotest: send to \(value)")
        self.target = target
        startTestSend()
    }
}
