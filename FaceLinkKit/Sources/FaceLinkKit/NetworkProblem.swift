import Network

/// 보내기·찾기에서 난 네트워크 문제. 화면 문구는 앱이 만든다
public enum NetworkProblem: Equatable, Sendable {
    /// 로컬 네트워크 권한이 꺼져 있다 (설정 › 개인정보 보호 및 보안 › 로컬 네트워크)
    case localNetworkDenied
    case network(String)

    /// kDNSServiceErr_PolicyDenied: Bonjour가 로컬 네트워크 권한 때문에 막힘
    private static let dnsPolicyDenied: Int32 = -65570

    public init(_ error: NWError) {
        if case .dns(let code) = error, code == Self.dnsPolicyDenied {
            self = .localNetworkDenied
        } else {
            self = .network(error.debugDescription)
        }
    }
}
