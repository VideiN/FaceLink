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
