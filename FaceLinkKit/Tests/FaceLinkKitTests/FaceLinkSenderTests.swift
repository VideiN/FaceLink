import Darwin
import Foundation
import Testing
@testable import FaceLinkKit

/// 받는 쪽 흉내: 루프백 UDP 소켓
private final class LoopbackSocket {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        var length = size
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        close(descriptor)
    }

    /// 0.1초 안에 온 데이터그램 하나와 보낸 주소
    func receive() -> (bytes: [UInt8], from: sockaddr_in)? {
        let capacity = 65536
        var buffer = [UInt8](repeating: 0, count: capacity)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, capacity, 0, $0, &length) }
        }
        guard count > 0 else { return nil }
        return (Array(buffer[..<count]), from)
    }

    func send(_ bytes: [UInt8], to address: sockaddr_in) {
        var address = address
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes, bytes.count, 0, $0, size) }
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FaceLinkSender.Event] = []

    func append(_ event: FaceLinkSender.Event) {
        lock.withLock { events.append(event) }
    }

    func contains(_ predicate: (FaceLinkSender.Event) -> Bool) -> Bool {
        lock.withLock { events.contains(where: predicate) }
    }
}

private func wait(timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// 루프백으로: Hello(토큰) → 프레임 → Ack로 응답 확인 → Calibrate로 정면 보정
@Test func senderTalksToReceiver() throws {
    let receiver = try LoopbackSocket()
    let events = EventLog()
    let target = FaceLinkTarget(location: .address(host: "127.0.0.1", port: receiver.port), token: "tok")
    let sender = FaceLinkSender(
        configuration: .init(target: target, deviceName: "Test", appVersion: "0.1.0"),
        onEvent: { events.append($0) }
    )
    sender.start()
    defer { sender.stop() }

    var messages: [OSCMessage] = []
    var senderAddress: sockaddr_in?
    func receive(until condition: () -> Bool) -> Bool {
        wait {
            if let received = receiver.receive() {
                senderAddress = received.from
                messages += (try? OSCDecoder.messages(in: received.bytes)) ?? []
            }
            return condition()
        }
    }
    func count(_ address: String) -> Int {
        messages.filter { $0.address == address }.count
    }

    // 연결이 준비되면 바로 Hello
    #expect(receive { count(FaceLinkProtocol.Address.hello) > 0 })
    let hello = try #require(messages.first { $0.address == FaceLinkProtocol.Address.hello })
    #expect(hello.arguments[0] == .string("1"))
    #expect(hello.arguments[1] == .string("Test"))
    #expect(hello.arguments[4] == .string("tok"))
    #expect(hello.arguments[3] == .string(sender.currentStatus.sessionID))

    sender.send(SyntheticFace.frame(at: 0))
    #expect(receive { count(FaceLinkProtocol.Address.blendApply) == 1 })
    #expect(count(FaceLinkProtocol.Address.blendValue) == 52)
    #expect(messages.first { $0.address == FaceLinkProtocol.Address.frame }?.arguments.first == .int(1))
    func headPosition(_ index: Int) -> [OSCArgument] {
        let heads = messages.filter { $0.address == FaceLinkProtocol.Address.bonePosition && $0.arguments.first == .string("Head") }
        return Array(heads[index].arguments[1...3])
    }
    // 보정 전: 카메라 앞 35cm가 Unity 좌표로 +z
    #expect(headPosition(0) == [.float(0), .float(0), .float(0.35)])

    // Ack → 응답 있음, 왕복 시간
    let address = try #require(senderAddress)
    receiver.send(FaceLinkMessage.ack(lastSequence: 1, receiverFPS: 60, receiverName: "R").encoded(), to: address)
    #expect(wait { sender.currentStatus.lastAck != nil })
    let status = sender.currentStatus
    #expect(status.lastAck == FaceLinkAck(lastSequence: 1, receiverFPS: 60, receiverName: "R"))
    #expect(status.isResponding)
    #expect(status.roundTrip != nil)
    #expect(status.framesSent == 1)
    #expect(events.contains { $0 == .responding(true) })

    // Calibrate → 다음 프레임의 머리 위치가 0
    receiver.send(FaceLinkMessage.calibrate.encoded(), to: address)
    #expect(wait { events.contains { $0 == .calibrateRequested } })
    sender.send(SyntheticFace.frame(at: 0.5))
    #expect(receive { count(FaceLinkProtocol.Address.blendApply) == 2 })
    #expect(headPosition(1) == [.float(0), .float(0), .float(0)])
    #expect(events.contains { $0 == .calibrated })
    #expect(sender.currentStatus.isCalibrated)
}

/// 시각을 직접 넣어 시험한다 (CI에서는 Thread.sleep이 한참 늦을 수 있다)
@Test func frameRateLimiter() {
    func sentCount(frameRate: Int, times: [TimeInterval]) -> Int {
        var limiter = FrameRateLimiter(frameRate: frameRate)
        return times.filter { limiter.shouldSend(at: $0) }.count
    }
    let at60 = (0..<12).map { Double($0) / 60 }
    // 60Hz 공급원을 30Hz로: 하나 걸러
    #expect(sentCount(frameRate: 30, times: at60) == 6)
    #expect(sentCount(frameRate: 60, times: at60) == 12)
    // 조금 일찍 온 프레임(간격 15.5ms)도 60Hz로 보낸다
    #expect(sentCount(frameRate: 60, times: (0..<12).map { Double($0) * 0.0155 }) == 12)
    // 공급원이 설정보다 느리면 다 보낸다
    #expect(sentCount(frameRate: 60, times: (0..<12).map { Double($0) / 30 }) == 12)
}
