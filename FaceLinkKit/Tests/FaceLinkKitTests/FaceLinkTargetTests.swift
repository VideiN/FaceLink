import Foundation
import Testing
@testable import FaceLinkKit

@Test(arguments: [
    ("192.168.0.10:39539", "192.168.0.10", UInt16(39539)),
    (" 192.168.0.10:40000 ", "192.168.0.10", 40000),
    ("192.168.0.10", "192.168.0.10", 39539),
    ("my-ipad.local:39540", "my-ipad.local", 39540),
    ("[fe80::1%en0]:39541", "fe80::1%en0", 39541),
    ("[fe80::1]", "fe80::1", 39539),
    ("fe80::1", "fe80::1", 39539),
])
func addressParsing(input: String, host: String, port: UInt16) throws {
    let target = try #require(FaceLinkTarget(address: input))
    #expect(target.location == .address(host: host, port: port))
    #expect(target.token == "")
}

@Test(arguments: ["", ":39539", "192.168.0.10:", "192.168.0.10:0", "192.168.0.10:70000", "192.168.0.10:abc", "[fe80::1", "[fe80::1]x", "a b:1", "http://x"])
func badAddresses(input: String) {
    #expect(FaceLinkTarget(address: input) == nil)
}

@Test func targetDescriptionAndCoding() throws {
    let v6 = FaceLinkTarget(location: .address(host: "fe80::1", port: 39539))
    #expect(v6.addressDescription == "[fe80::1]:39539")
    #expect(v6.name == "[fe80::1]:39539")
    let service = FaceLinkTarget(location: .service(name: "iPad"), name: "내 iPad")
    #expect(service.addressDescription == "Bonjour: iPad")
    #expect(service.name == "내 iPad")
    // 마지막 대상을 기억할 때 JSON으로 저장한다
    for target in [v6, service, FaceLinkTarget(location: .address(host: "10.0.0.2", port: 1), name: "n", token: "t")] {
        let data = try JSONEncoder().encode(target)
        #expect(try JSONDecoder().decode(FaceLinkTarget.self, from: data) == target)
    }
}

@Test func syntheticFace() {
    let start = SyntheticFace.frame(at: 0)
    #expect(start.isTracked)
    #expect(start.head.position == SyntheticFace.headPosition)
    #expect(start.blendShapes[.jawOpen] == 0)
    #expect(SyntheticFace.frame(at: 1).blendShapes[.jawOpen]! > 0.99)
    // 0.1초에 눈을 다 감고 0.5초에는 떠 있다
    #expect(SyntheticFace.frame(at: 0.1).blendShapes[.eyeBlinkLeft]! > 0.99)
    #expect(SyntheticFace.frame(at: 0.5).blendShapes[.eyeBlinkLeft] == 0)
    // 1초에 머리가 한쪽으로 20도
    let angle = SyntheticFace.frame(at: 1).head.rotation.angle
    #expect(abs(angle - 20 * .pi / 180) < 1e-4)
    // 값은 늘 0~1
    for step in 0..<400 {
        let frame = SyntheticFace.frame(at: Double(step) * 0.01)
        #expect(frame.blendShapes.values.allSatisfy { (0...1).contains($0) })
    }
}

/// QR 주소 (docs/face-link.md 3.4)
@Test func qrURLParsing() throws {
    let target = try FaceLinkTarget(url: "facelink://192.168.0.20:39540?v=1&name=%EB%82%B4%20iPad&token=k3x9")
    #expect(target.location == .address(host: "192.168.0.20", port: 39540))
    #expect(target.name == "내 iPad")
    #expect(target.token == "k3x9")

    // v가 없으면 1, 이름이 없으면 주소, 포트가 없으면 기본 포트, 대소문자 무시
    let minimal = try FaceLinkTarget(url: "FaceLink://10.0.0.5")
    #expect(minimal.location == .address(host: "10.0.0.5", port: 39539))
    #expect(minimal.name == "10.0.0.5:39539")
    #expect(minimal.token == "")

    let v6 = try FaceLinkTarget(url: "facelink://[fe80::1]:39539/?token=t")
    #expect(v6.location == .address(host: "fe80::1", port: 39539))
    #expect(v6.token == "t")
}

@Test func badQRURLs() {
    #expect(throws: TargetURLError.notFaceLink) { try FaceLinkTarget(url: "https://example.com") }
    #expect(throws: TargetURLError.notFaceLink) { try FaceLinkTarget(url: "192.168.0.1:39539") }
    #expect(throws: TargetURLError.unsupportedVersion("2")) { try FaceLinkTarget(url: "facelink://192.168.0.1:39539?v=2") }
    #expect(throws: TargetURLError.invalidAddress) { try FaceLinkTarget(url: "facelink://?v=1") }
    #expect(throws: TargetURLError.invalidAddress) { try FaceLinkTarget(url: "facelink://192.168.0.1:0") }
}

@Test func urlOrAddress() {
    #expect(FaceLinkTarget(urlOrAddress: "facelink://10.0.0.5:4000?token=a")?.token == "a")
    #expect(FaceLinkTarget(urlOrAddress: "10.0.0.5:4000")?.location == .address(host: "10.0.0.5", port: 4000))
    #expect(FaceLinkTarget(urlOrAddress: "facelink://") == nil)
}

@Test func networkProblemFromError() {
    #expect(NetworkProblem(.posix(.ECONNREFUSED)) == .receiverNotListening)
    #expect(NetworkProblem(.dns(-65570)) == .localNetworkDenied)
    if case .network = NetworkProblem(.posix(.ENETUNREACH)) {} else {
        Issue.record("ENETUNREACH should be a plain network problem")
    }
}
