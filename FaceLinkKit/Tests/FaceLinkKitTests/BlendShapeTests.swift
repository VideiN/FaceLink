import Testing
@testable import FaceLinkKit

/// docs/face-link.md 부록 A의 괄호 안 값 (ARKit 원래 문자열), 같은 순서
private let arkitNamesInAppendixA = [
    "eyeBlink_L", "eyeLookDown_L", "eyeLookIn_L", "eyeLookOut_L", "eyeLookUp_L", "eyeSquint_L", "eyeWide_L",
    "eyeBlink_R", "eyeLookDown_R", "eyeLookIn_R", "eyeLookOut_R", "eyeLookUp_R", "eyeSquint_R", "eyeWide_R",
    "jawForward", "jawLeft", "jawRight", "jawOpen",
    "mouthClose", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
    "mouthSmile_L", "mouthSmile_R", "mouthFrown_L", "mouthFrown_R", "mouthDimple_L", "mouthDimple_R",
    "mouthStretch_L", "mouthStretch_R", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthPress_L", "mouthPress_R", "mouthLowerDown_L", "mouthLowerDown_R", "mouthUpperUp_L", "mouthUpperUp_R",
    "browDown_L", "browDown_R", "browInnerUp", "browOuterUp_L", "browOuterUp_R",
    "cheekPuff", "cheekSquint_L", "cheekSquint_R", "noseSneer_L", "noseSneer_R",
    "tongueOut",
]

@Test func fiftyTwoShapes() {
    #expect(BlendShape.allCases.count == 52)
    #expect(Set(BlendShape.allCases.map(\.name)).count == 52)
}

/// 보내는 이름 = Swift 이름을 대문자로 시작하게
@Test func nameIsCapitalizedSwiftName() {
    for shape in BlendShape.allCases {
        let swiftName = String(describing: shape)
        #expect(shape.name == swiftName.prefix(1).uppercased() + swiftName.dropFirst())
    }
}

@Test func arkitNamesMatchAppendixA() {
    #expect(BlendShape.allCases.map(\.arkitName) == arkitNamesInAppendixA)
}

/// ARKit이 주는 문자열로 찾기 (ARKit 얼굴 추적 → FaceFrame)
@Test func lookupByARKitName() {
    for (shape, arkitName) in zip(BlendShape.allCases, arkitNamesInAppendixA) {
        #expect(BlendShape(arkitName: arkitName) == shape)
    }
    #expect(BlendShape(arkitName: "EyeBlinkLeft") == nil)
    #expect(BlendShape(arkitName: "eyeBlinkLeft") == nil)
}
