import Foundation
import Synchronization

/// 앱 로그. 표준 출력으로 내보내고(CI는 `simctl launch --console-pty`로 받아 줄을 찾는다),
/// 최근 줄은 메모리에 남겨 앱의 "기록" 화면에서 보고 공유한다 (실기기 시험용)
nonisolated func log(_ message: String) {
    print(message)
    AppLog.shared.append(message)
}

nonisolated final class AppLog: Sendable {
    static let shared = AppLog()

    private static let capacity = 1000
    private let lines = Mutex<[String]>([])

    func append(_ message: String) {
        let line = "\(Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))) \(message)"
        lines.withLock { lines in
            lines.append(line)
            if lines.count > Self.capacity {
                lines.removeFirst(lines.count - Self.capacity)
            }
        }
    }

    var text: String {
        lines.withLock { $0.joined(separator: "\n") }
    }
}
