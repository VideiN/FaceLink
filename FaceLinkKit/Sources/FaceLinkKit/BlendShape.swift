/// ARKit 블렌드셰이프 52개 (docs/face-link.md 부록 A). 순서는 부록 A와 같고, 이 순서로 보낸다.
///
/// `rawValue`는 보내는 이름("Perfect Sync" 표기): ARKit `ARFaceAnchor.BlendShapeLocation`의 Swift 이름을 대문자로 시작하게.
public enum BlendShape: String, CaseIterable, Sendable {
    // 왼눈
    case eyeBlinkLeft = "EyeBlinkLeft"
    case eyeLookDownLeft = "EyeLookDownLeft"
    case eyeLookInLeft = "EyeLookInLeft"
    case eyeLookOutLeft = "EyeLookOutLeft"
    case eyeLookUpLeft = "EyeLookUpLeft"
    case eyeSquintLeft = "EyeSquintLeft"
    case eyeWideLeft = "EyeWideLeft"
    // 오른눈
    case eyeBlinkRight = "EyeBlinkRight"
    case eyeLookDownRight = "EyeLookDownRight"
    case eyeLookInRight = "EyeLookInRight"
    case eyeLookOutRight = "EyeLookOutRight"
    case eyeLookUpRight = "EyeLookUpRight"
    case eyeSquintRight = "EyeSquintRight"
    case eyeWideRight = "EyeWideRight"
    // 턱
    case jawForward = "JawForward"
    case jawLeft = "JawLeft"
    case jawRight = "JawRight"
    case jawOpen = "JawOpen"
    // 입
    case mouthClose = "MouthClose"
    case mouthFunnel = "MouthFunnel"
    case mouthPucker = "MouthPucker"
    case mouthLeft = "MouthLeft"
    case mouthRight = "MouthRight"
    case mouthSmileLeft = "MouthSmileLeft"
    case mouthSmileRight = "MouthSmileRight"
    case mouthFrownLeft = "MouthFrownLeft"
    case mouthFrownRight = "MouthFrownRight"
    case mouthDimpleLeft = "MouthDimpleLeft"
    case mouthDimpleRight = "MouthDimpleRight"
    case mouthStretchLeft = "MouthStretchLeft"
    case mouthStretchRight = "MouthStretchRight"
    case mouthRollLower = "MouthRollLower"
    case mouthRollUpper = "MouthRollUpper"
    case mouthShrugLower = "MouthShrugLower"
    case mouthShrugUpper = "MouthShrugUpper"
    case mouthPressLeft = "MouthPressLeft"
    case mouthPressRight = "MouthPressRight"
    case mouthLowerDownLeft = "MouthLowerDownLeft"
    case mouthLowerDownRight = "MouthLowerDownRight"
    case mouthUpperUpLeft = "MouthUpperUpLeft"
    case mouthUpperUpRight = "MouthUpperUpRight"
    // 눈썹
    case browDownLeft = "BrowDownLeft"
    case browDownRight = "BrowDownRight"
    case browInnerUp = "BrowInnerUp"
    case browOuterUpLeft = "BrowOuterUpLeft"
    case browOuterUpRight = "BrowOuterUpRight"
    // 볼·코
    case cheekPuff = "CheekPuff"
    case cheekSquintLeft = "CheekSquintLeft"
    case cheekSquintRight = "CheekSquintRight"
    case noseSneerLeft = "NoseSneerLeft"
    case noseSneerRight = "NoseSneerRight"
    // 혀
    case tongueOut = "TongueOut"

    /// 보내는 이름 (`/VMC/Ext/Blend/Val`의 첫 인자)
    public var name: String { rawValue }

    private static let byARKitName = Dictionary(uniqueKeysWithValues: allCases.map { ($0.arkitName, $0) })

    /// ARKit의 원래 문자열(`ARFaceAnchor.BlendShapeLocation.rawValue`)에서. 모르는 이름이면 nil
    public init?(arkitName: String) {
        guard let shape = Self.byARKitName[arkitName] else { return nil }
        self = shape
    }

    /// ARKit의 원래 문자열 (`ARFaceAnchor.BlendShapeLocation.rawValue`, 예: "eyeBlink_L").
    /// 끝의 Left/Right는 _L/_R이 되지만 jawLeft·jawRight·mouthLeft·mouthRight는 그대로다.
    public var arkitName: String {
        let lower = rawValue.prefix(1).lowercased() + rawValue.dropFirst()
        switch self {
        case .jawLeft, .jawRight, .mouthLeft, .mouthRight:
            return lower
        default:
            if lower.hasSuffix("Left") { return String(lower.dropLast(4)) + "_L" }
            if lower.hasSuffix("Right") { return String(lower.dropLast(5)) + "_R" }
            return lower
        }
    }
}
