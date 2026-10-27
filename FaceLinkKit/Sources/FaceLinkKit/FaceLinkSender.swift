import Foundation
import Network

/// FaceLink v1로 얼굴 프레임(v1.1: 몸 뼈, 소리 패킷도)을 보내고, 받는 쪽의 Ack·Calibrate를 받는다 (docs/face-link.md 3장).
/// 보내는 값은 정면 보정 뒤의 값이라 보정도 여기서 한다.
/// 상태는 모두 `queue`에서만 만진다 (그래서 @unchecked Sendable). 보내기를 시작할 때마다 새로 만든다
public final class FaceLinkSender: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var target: FaceLinkTarget
        /// Hello의 기기 이름
        public var deviceName: String
        /// Hello의 앱 버전
        public var appVersion: String
        /// 초당 프레임 (60 또는 30). 공급원이 이보다 빠르면 프레임을 건너뛴다
        public var frameRate: Int
        public var sendEyes: Bool
        public var sendHeadPosition: Bool
        /// 보내는 것 (v1.1, Hello의 기능). 얼굴은 늘 들어 있다. body·hands가 없으면 몸을, audio가 없으면 소리를 버린다
        public var features: Set<FaceLinkFeature>

        public init(
            target: FaceLinkTarget,
            deviceName: String,
            appVersion: String,
            frameRate: Int = 60,
            sendEyes: Bool = true,
            sendHeadPosition: Bool = true,
            features: Set<FaceLinkFeature> = [.face]
        ) {
            self.target = target
            self.deviceName = deviceName
            self.appVersion = appVersion
            self.frameRate = frameRate
            self.sendEyes = sendEyes
            self.sendHeadPosition = sendHeadPosition
            self.features = features.union([.face])
        }

        var sendsBody: Bool { features.contains(.body) || features.contains(.hands) }
    }

    /// 로그와 화면에 알릴 일
    public enum Event: Equatable, Sendable, CustomStringConvertible {
        case ready
        case connectionProblem(NetworkProblem)
        /// 문제가 풀림 (보내기가 2초 넘게 실패하지 않음)
        case problemCleared
        case ack(FaceLinkAck, roundTrip: TimeInterval?)
        /// Ack가 오기 시작함(true) 또는 3초 넘게 없음(false)
        case responding(Bool)
        /// 받는 쪽이 "정면 맞추기"를 누름
        case calibrateRequested
        /// 정면 보정을 했다 (다음 추적 프레임의 머리 자세가 기준)
        case calibrated

        public var description: String {
            switch self {
            case .ready: "ready"
            case .connectionProblem(let problem): "problem \(problem)"
            case .problemCleared: "problem cleared"
            case .ack(let ack, let roundTrip):
                "ack from \(ack.receiverName) (seq \(ack.lastSequence), \(ack.receiverFPS) fps, rtt \(roundTrip.map { "\(Int($0 * 1000)) ms" } ?? "?"))"
            case .responding(let responding): responding ? "responding" : "no response for 3 s"
            case .calibrateRequested: "calibrate requested by receiver"
            case .calibrated: "calibrated"
            }
        }
    }

    public struct Status: Equatable, Sendable {
        public var sessionID = ""
        public var framesSent = 0
        /// 지난 1초 동안 보낸 프레임
        public var sendFPS = 0
        /// 마지막으로 보낸 프레임에 얼굴이 있었는지
        public var isTracking = false
        /// 3초 안에 Ack가 왔는지 (3.5)
        public var isResponding = false
        public var lastAck: FaceLinkAck?
        /// 대략의 왕복 시간 (초)
        public var roundTrip: TimeInterval?
        public var isCalibrated = false
        public var problem: NetworkProblem?
        /// v1.1: 몸을 얹어 보낸 프레임 (지난 1초, 모두)
        public var bodyFPS = 0
        public var bodyFramesSent = 0
        /// v1.1: 보낸 소리 패킷 (지난 1초, 모두)
        public var audioPacketsPerSecond = 0
        public var audioPacketsSent = 0
        /// v1.1: 지난 1초 동안 들어온 소리의 가장 큰 값 (0~1, 음소거 중에도 잰다)
        public var audioPeak: Float = 0
        public var isAudioMuted = false

        public init() {}
    }

    /// Ack가 이만큼(초) 없으면 "응답 없음" (3.5)
    public static let responseTimeout: TimeInterval = 3

    public let configuration: Configuration
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "FaceLinkSender", qos: .userInteractive)
    private let encoder: FaceLinkEncoder

    private var running = false
    private var connection: NWConnection?
    /// 연결을 새로 열 때마다 늘린다. 닫은 연결에서 늦게 온 콜백을 버리는 데 쓴다
    private var generation = 0
    private var isReady = false
    private var timer: DispatchSourceTimer?
    private var session = FaceLinkSession(startTime: 0)
    private var roundTrips = RoundTripTracker()
    private var calibration = HeadCalibration()
    private var calibrationRequested = false
    private var rateLimiter: FrameRateLimiter
    /// 다음 얼굴 프레임에 얹을 몸 (v1.1)
    private var pendingBody: BodyPose?
    private var audioPacketizer = AudioPacketizer()
    private var framesThisSecond = 0
    private var bodyFramesThisSecond = 0
    private var audioPacketsThisSecond = 0
    private var audioPeakThisSecond: Float = 0
    /// takeAudioPeak()를 부른 뒤로 가장 큰 값
    private var audioPeakSinceTake: Float = 0
    private var lastAckTime: TimeInterval?
    private var lastProblemTime: TimeInterval = 0
    private var status = Status()

    public init(configuration: Configuration, onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.configuration = configuration
        self.onEvent = onEvent
        encoder = FaceLinkEncoder(sendEyes: configuration.sendEyes, sendHeadPosition: configuration.sendHeadPosition)
        rateLimiter = FrameRateLimiter(frameRate: configuration.frameRate)
    }

    deinit {
        timer?.cancel()
        connection?.cancel()
    }

    /// 새 세션으로 보내기를 시작한다
    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// 공급원 스레드에서 불러도 된다. 연결이 준비되기 전의 프레임은 버린다
    public func send(_ frame: FaceFrame) {
        queue.async { self.sendOnQueue(frame) }
    }

    /// 몸 (v1.1): 다음에 보내는 얼굴 프레임에 얹는다 (몸은 15~30Hz, 얼굴은 60Hz라). 공급원 스레드에서 불러도 된다.
    /// 기능에 body·hands가 없으면 버린다
    public func sendBody(_ body: BodyPose) {
        guard configuration.sendsBody else { return }
        queue.async { self.pendingBody = body }
    }

    /// 소리 (v1.1, 3.8): 48 kHz 모노 s16 표본을 10ms씩 끊어 얼굴과 같은 연결로 보낸다
    /// (받는 쪽은 출발 주소·포트로 보내는 쪽을 가리고, 받는 중인 쪽의 소리만 쓴다). 공급원 스레드에서 불러도 된다.
    /// 기능에 audio가 없거나 연결이 준비되기 전의 표본은 버린다
    public func sendAudio(_ samples: [Int16]) {
        guard configuration.features.contains(.audio) else { return }
        queue.async { self.sendAudioOnQueue(samples) }
    }

    /// 음소거 (4.7): 표본을 자르개에 넣기 전에 버린다. 패킷이 안 가면 받는 쪽은 0.5초 뒤 무음으로 둔다.
    /// 다시 켜면 순번이 이어진다 (받는 쪽이 빠진 패킷으로 세지 않게). Hello의 기능에서 audio는 빼지 않는다
    public func setAudioMuted(_ muted: Bool) {
        queue.async { self.status.isAudioMuted = muted }
    }

    /// 지난번에 부른 뒤로 들어온 소리의 가장 큰 값 (0~1, 음소거 중에도). 화면의 레벨 막대가 0.1초마다 읽는다
    public func takeAudioPeak() -> Float {
        queue.sync {
            let peak = audioPeakSinceTake
            audioPeakSinceTake = 0
            return peak
        }
    }

    /// 정면 보정: 다음 추적 프레임의 머리 자세를 기준으로 삼는다
    public func calibrate() {
        queue.async { self.calibrationRequested = true }
    }

    public var currentStatus: Status {
        queue.sync { status }
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: - queue에서만

    private func startOnQueue() {
        guard !running else { return }
        running = true
        session = FaceLinkSession(startTime: Self.now)
        pendingBody = nil
        audioPacketizer = AudioPacketizer()
        status = Status()
        status.sessionID = session.id
        status.isCalibrated = calibration.reference != nil
        openConnection()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func stopOnQueue() {
        running = false
        timer?.cancel()
        timer = nil
        closeConnection()
    }

    private func openConnection() {
        generation += 1
        isReady = false
        let connection = NWConnection(to: configuration.target.endpoint, using: .udp)
        let currentGeneration = generation
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == currentGeneration else { return }
            self.connectionStateChanged(state)
        }
        self.connection = connection
        connection.start(queue: queue)
        receiveNext()
    }

    private func closeConnection() {
        generation += 1
        isReady = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            status.problem = nil
            onEvent(.ready)
            sendHello()
        case .waiting(let error):
            isReady = false
            report(problem(for: error))
        case .failed(let error):
            isReady = false
            report(problem(for: error))
            // 잠깐 쉬고 다시 연다 (같은 세션)
            let currentGeneration = generation
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.running, self.generation == currentGeneration else { return }
                self.closeConnection()
                self.openConnection()
            }
        default:
            break
        }
    }

    private func problem(for error: NWError) -> NetworkProblem {
        if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
            return .localNetworkDenied
        }
        return NetworkProblem(error)
    }

    /// 같은 문제를 거듭 알리지 않는다 (보내기 실패는 프레임마다 날 수 있다)
    private func report(_ problem: NetworkProblem) {
        lastProblemTime = Self.now
        guard status.problem != problem else { return }
        status.problem = problem
        onEvent(.connectionProblem(problem))
    }

    private func receiveNext() {
        guard let connection else { return }
        let currentGeneration = generation
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == currentGeneration else { return }
            if let data, !data.isEmpty {
                self.handleIncoming([UInt8](data))
            }
            if error == nil {
                self.receiveNext()
            } else {
                // 받는 쪽이 아직 없으면(포트 닫힘) 오류가 난다. 잠깐 쉬고 다시 받는다
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.receiveNext()
                }
            }
        }
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        guard let messages = try? OSCDecoder.messages(in: bytes) else { return }
        let now = Self.now
        for message in messages {
            switch FaceLinkInbound(message) {
            case .ack(let ack):
                lastAckTime = now
                let roundTrip = roundTrips.roundTrip(forAck: ack.lastSequence, receivedAt: now)
                status.lastAck = ack
                status.roundTrip = roundTrip
                if !status.isResponding {
                    status.isResponding = true
                    onEvent(.responding(true))
                }
                onEvent(.ack(ack, roundTrip: roundTrip))
            case .calibrate:
                calibrationRequested = true
                onEvent(.calibrateRequested)
            case nil:
                break
            }
        }
    }

    /// 1초마다: Hello, 보내는 fps, Ack가 끊겼는지
    private func tick() {
        let now = Self.now
        status.sendFPS = framesThisSecond
        status.bodyFPS = bodyFramesThisSecond
        status.audioPacketsPerSecond = audioPacketsThisSecond
        status.audioPeak = audioPeakThisSecond
        framesThisSecond = 0
        bodyFramesThisSecond = 0
        audioPacketsThisSecond = 0
        audioPeakThisSecond = 0
        sendHello()
        let responding = lastAckTime.map { now - $0 <= Self.responseTimeout } ?? false
        if responding != status.isResponding {
            status.isResponding = responding
            onEvent(.responding(responding))
        }
        // 받는 쪽이 다시 살아나면 보내기 오류가 그친다. 연결이 준비된 채로 2초 동안 오류가 없으면 문제를 지운다
        // (UDP는 포트 닫힘 오류가 보내기 한 번 걸러 오므로 보내기가 한 번 성공했다고 바로 지우지 않는다)
        if status.problem != nil, isReady, now - lastProblemTime > 2 {
            status.problem = nil
            onEvent(.problemCleared)
        }
    }

    private func sendHello() {
        let hello = FaceLinkMessage.hello(
            deviceName: configuration.deviceName,
            appVersion: configuration.appVersion,
            sessionID: session.id,
            token: configuration.target.token,
            features: configuration.features
        )
        sendDatagram(hello.encoded())
    }

    private func sendOnQueue(_ frame: FaceFrame) {
        guard running, isReady else { return }
        let now = Self.now
        guard rateLimiter.shouldSend(at: now) else { return }

        var frame = frame
        if calibrationRequested && frame.isTracked {
            calibration.setReference(frame.head)
            calibrationRequested = false
            status.isCalibrated = true
            onEvent(.calibrated)
        }
        frame.head = calibration.apply(to: frame.head)

        // 건너뛴 프레임 사이에 온 몸도 여기서 보낸다 (가장 새것만)
        let body = pendingBody
        pendingBody = nil

        let sequence = session.takeSequence()
        for datagram in encoder.datagrams(for: frame, body: body, sequence: sequence, time: session.time(at: now)) {
            sendDatagram(datagram)
        }
        roundTrips.recordSent(sequence, at: now)
        framesThisSecond += 1
        status.framesSent += 1
        status.isTracking = frame.isTracked
        if body != nil {
            bodyFramesThisSecond += 1
            status.bodyFramesSent += 1
        }
    }

    private func sendAudioOnQueue(_ samples: [Int16]) {
        guard running else { return }
        // 레벨은 음소거 중에도, 연결이 준비되기 전에도 잰다 (마이크가 살아 있는지 보이게)
        let peak = Float(samples.lazy.map { Int($0).magnitude }.max() ?? 0) / 32768
        audioPeakThisSecond = max(audioPeakThisSecond, peak)
        audioPeakSinceTake = max(audioPeakSinceTake, peak)
        guard isReady, !status.isAudioMuted else { return }
        for packet in audioPacketizer.packets(appending: samples) {
            sendDatagram(packet)
            audioPacketsThisSecond += 1
            status.audioPacketsSent += 1
        }
    }

    private func sendDatagram(_ bytes: [UInt8]) {
        guard isReady, let connection else { return }
        let currentGeneration = generation
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let error, let self, self.generation == currentGeneration else { return }
            self.report(self.problem(for: error))
        })
    }
}
