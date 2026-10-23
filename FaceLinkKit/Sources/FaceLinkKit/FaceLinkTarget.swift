import Foundation
import Network

/// 보낼 곳: 받는 쪽(아이패드의 Broadcast, 또는 VMC를 받는 프로그램) (docs/face-link.md 3.4)
public struct FaceLinkTarget: Codable, Hashable, Sendable {
    public enum Location: Codable, Hashable, Sendable {
        case address(host: String, port: UInt16)
        /// Bonjour 서비스 이름 (`_facelink._udp`, local.)
        case service(name: String)
    }

    public var location: Location
    /// 화면에 보일 이름. QR·Bonjour TXT의 name, 없으면 주소
    public var name: String
    /// 페어링 토큰 (QR에만 있다). 없으면 ""
    public var token: String

    public init(location: Location, name: String? = nil, token: String = "") {
        self.location = location
        self.token = token
        switch location {
        case .address(let host, let port):
            self.name = name ?? Self.hostPort(host, port)
        case .service(let serviceName):
            self.name = name ?? serviceName
        }
    }

    /// "192.168.0.10:39539", "[fe80::1]:39539". 포트를 빼면 기본 포트
    public init?(address input: String, defaultPort: UInt16 = FaceLinkProtocol.defaultPort) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        var portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = text[..<colon]
            portText = text[text.index(after: colon)...]
        } else {
            // 주소만, 또는 괄호 없는 IPv6
            host = Substring(text)
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        var port = defaultPort
        if let portText {
            guard let value = UInt16(portText), value > 0 else { return nil }
            port = value
        }
        self.init(location: .address(host: String(host), port: port))
    }

    public var endpoint: NWEndpoint {
        switch location {
        case .address(let host, let port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: FaceLinkProtocol.defaultPort))
        case .service(let name):
            .service(name: name, type: FaceLinkProtocol.bonjourServiceType, domain: "local.", interface: nil)
        }
    }

    /// "192.168.0.10:39539" 또는 "Bonjour: 이름"
    public var addressDescription: String {
        switch location {
        case .address(let host, let port): Self.hostPort(host, port)
        case .service(let name): "Bonjour: \(name)"
        }
    }

    private static func hostPort(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
