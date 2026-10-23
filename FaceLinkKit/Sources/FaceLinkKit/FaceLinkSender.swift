import Foundation
import Network

/// FaceLink v1로 얼굴 프레임을 보내고, 받는 쪽의 Ack·Calibrate를 받는다 (docs/face-link.md 3장).
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

        public init(
            target: FaceLinkTarget,
            deviceName: String,
            appVersion: String,
            frameRate: Int = 60,
            sendEyes: Bool = true,
            sendHeadPosition: Bool = true
        ) {
            self.target = target
            self.deviceName = deviceName
            self.appVersion = appVersion
            self.frameRate = frameRate
            self.sendEyes = sendEyes
            self.sendHeadPosition = sendHeadPosition
        }
    }

    /// 로그와 화면에 알릴 일
    public enum Event: Equatable, Sendable, CustomStringConvertible {
        case ready
        case connectionProblem(NetworkProblem)
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
    private var framesThisSecond = 0
    private var lastAckTime: TimeInterval?
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
        framesThisSecond = 0
        sendHello()
        let responding = lastAckTime.map { now - $0 <= Self.responseTimeout } ?? false
        if responding != status.isResponding {
            status.isResponding = responding
            onEvent(.responding(responding))
        }
    }

    private func sendHello() {
        let hello = FaceLinkMessage.hello(
            deviceName: configuration.deviceName,
            appVersion: configuration.appVersion,
            sessionID: session.id,
            token: configuration.target.token
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

        let sequence = session.takeSequence()
        for datagram in encoder.datagrams(for: frame, sequence: sequence, time: session.time(at: now)) {
            sendDatagram(datagram)
        }
        roundTrips.recordSent(sequence, at: now)
        framesThisSecond += 1
        status.framesSent += 1
        status.isTracking = frame.isTracked
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
