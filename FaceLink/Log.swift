import Foundation

/// 앱 로그. 표준 출력으로 내보낸다: CI는 `simctl launch --console-pty`로 받아 줄을 찾는다
nonisolated func log(_ message: String) {
    print(message)
}
