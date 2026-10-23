import Foundation

/// QR 주소를 읽지 못한 까닭
public enum TargetURLError: Error, Equatable, Sendable {
    /// facelink:// 주소가 아니다
    case notFaceLink
    /// 다른 프로토콜 버전 (v=)
    case unsupportedVersion(String)
    case invalidAddress
}

extension FaceLinkTarget {
    public static let urlScheme = "facelink"

    /// 받는 쪽이 QR로 보여 주는 주소 (docs/face-link.md 3.4):
    /// `facelink://<IP>:<포트>?v=1&name=<이름>&token=<토큰>`. IPv6는 `[...]`로 감싼다. v가 없으면 1로 본다
    public init(url text: String) throws(TargetURLError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = Self.urlScheme + "://"
        guard trimmed.lowercased().hasPrefix(prefix) else { throw .notFaceLink }

        // 주소 부분은 직접 입력과 같은 규칙으로 읽는다
        let rest = trimmed.dropFirst(prefix.count)
        let authorityEnd = rest.firstIndex { $0 == "?" || $0 == "/" || $0 == "#" } ?? rest.endIndex
        guard let address = FaceLinkTarget(address: String(rest[..<authorityEnd])),
              case .address(let host, let port) = address.location
        else { throw .invalidAddress }

        let items = URLComponents(string: trimmed)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let version = value("v"), version != FaceLinkProtocol.version {
            throw .unsupportedVersion(version)
        }
        let name = value("name").flatMap { $0.isEmpty ? nil : $0 }
        self.init(location: .address(host: host, port: port), name: name, token: value("token") ?? "")
    }

    /// 실행 인자·붙여 넣기용: facelink:// 주소이거나 "IP:포트"
    public init?(urlOrAddress text: String) {
        if text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(Self.urlScheme + "://") {
            guard let target = try? FaceLinkTarget(url: text) else { return nil }
            self = target
        } else {
            self.init(address: text)
        }
    }
}
