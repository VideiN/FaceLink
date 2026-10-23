// swift-tools-version: 6.0
// FaceLink v1 프로토콜 (docs/face-link.md). Apple 프레임워크만 쓰는 순수 Swift라 macOS에서 `swift test`로 바로 시험한다.
import PackageDescription

let package = Package(
    name: "FaceLinkKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FaceLinkKit", targets: ["FaceLinkKit"]),
    ],
    targets: [
        .target(name: "FaceLinkKit"),
        .testTarget(name: "FaceLinkKitTests", dependencies: ["FaceLinkKit"]),
    ]
)
