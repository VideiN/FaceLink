import Foundation

/// 공급원(ARKit은 60fps)이 설정 속도(60/30Hz)보다 빠르면 프레임을 건너뛴다.
/// 조금 일찍 온 프레임도 받게 간격에 10% 여유를 둔다
public struct FrameRateLimiter: Sendable {
    public let frameRate: Int
    private var lastTime = -TimeInterval.infinity

    public init(frameRate: Int) {
        self.frameRate = frameRate
    }

    /// 보낼 프레임이면 true (그 시각을 기억한다)
    public mutating func shouldSend(at time: TimeInterval) -> Bool {
        guard time - lastTime >= 0.9 / Double(frameRate) else { return false }
        lastTime = time
        return true
    }
}
