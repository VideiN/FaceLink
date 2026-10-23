import Network

/// 보내기·찾기에서 난 네트워크 문제. 화면 문구는 앱이 만든다
public enum NetworkProblem: Equatable, Sendable {
    /// 로컬 네트워크 권한이 꺼져 있다 (설정 › 개인정보 보호 및 보안 › 로컬 네트워크)
    case localNetworkDenied
    /// 받는 쪽 포트가 닫혀 있다 (ICMP 포트 닫힘 → ECONNREFUSED). 받는 쪽 앱이 꺼졌거나 얼굴 추적을 켜지 않았다
    case receiverNotListening
    case network(String)

    /// kDNSServiceErr_PolicyDenied: Bonjour가 로컬 네트워크 권한 때문에 막힘
    private static let dnsPolicyDenied: Int32 = -65570

    public init(_ error: NWError) {
        switch error {
        case .dns(let code) where code == Self.dnsPolicyDenied:
            self = .localNetworkDenied
        case .posix(.ECONNREFUSED):
            self = .receiverNotListening
        default:
            self = .network(error.debugDescription)
        }
    }
}
