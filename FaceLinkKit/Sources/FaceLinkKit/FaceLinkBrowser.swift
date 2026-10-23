import Foundation
import Network

/// 같은 Wi-Fi의 받는 쪽을 Bonjour로 찾는다 (`_facelink._udp`, docs/face-link.md 3.4).
/// 상태는 queue에서만 만진다. 콜백은 queue에서 부른다
public final class FaceLinkBrowser: @unchecked Sendable {
    public struct Service: Hashable, Sendable, Identifiable {
        /// Bonjour 서비스 이름
        public var serviceName: String
        /// TXT의 name. 없으면 서비스 이름
        public var displayName: String
        /// TXT의 v (프로토콜 버전)
        public var version: String?

        public var id: String { serviceName }

        public var target: FaceLinkTarget {
            FaceLinkTarget(location: .service(name: serviceName), name: displayName)
        }

        public init(serviceName: String, displayName: String, version: String?) {
            self.serviceName = serviceName
            self.displayName = displayName
            self.version = version
        }
    }

    private let queue = DispatchQueue(label: "FaceLinkBrowser")
    private let onChange: @Sendable ([Service]) -> Void
    private let onProblem: @Sendable (NetworkProblem?) -> Void
    private var browser: NWBrowser?

    /// onChange: 찾은 목록이 바뀔 때 (이름순). onProblem: 문제가 생기거나(값) 풀릴 때(nil)
    public init(
        onChange: @escaping @Sendable ([Service]) -> Void,
        onProblem: @escaping @Sendable (NetworkProblem?) -> Void = { _ in }
    ) {
        self.onChange = onChange
        self.onProblem = onProblem
    }

    deinit {
        browser?.cancel()
    }

    public func start() {
        queue.async {
            guard self.browser == nil else { return }
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: FaceLinkProtocol.bonjourServiceType, domain: nil),
                using: NWParameters()
            )
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.resultsChanged(results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                self?.stateChanged(state)
            }
            self.browser = browser
            browser.start(queue: self.queue)
        }
    }

    public func stop() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        let services = results.compactMap { result -> Service? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            var displayName = name
            var version: String?
            if case .bonjour(let record) = result.metadata {
                if let recordName = record["name"], !recordName.isEmpty {
                    displayName = recordName
                }
                version = record["v"]
            }
            return Service(serviceName: name, displayName: displayName, version: version)
        }
        onChange(services.sorted { ($0.displayName, $0.serviceName) < ($1.displayName, $1.serviceName) })
    }

    private func stateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            onProblem(nil)
        case .waiting(let error), .failed(let error):
            onProblem(NetworkProblem(error))
        default:
            break
        }
    }
}
