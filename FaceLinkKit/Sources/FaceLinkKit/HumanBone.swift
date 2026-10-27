import simd

/// 몸 뼈 이름 (docs/face-link.md 3.2, v1.1): Unity `HumanBodyBones`와 같은 55개, 같은 순서. rawValue가 보내는 이름이다.
/// 엄지도 Unity 이름이다 (Proximal이 손바닥 쪽 첫 마디)
public enum HumanBone: String, CaseIterable, Sendable {
    case hips = "Hips"
    case leftUpperLeg = "LeftUpperLeg", rightUpperLeg = "RightUpperLeg"
    case leftLowerLeg = "LeftLowerLeg", rightLowerLeg = "RightLowerLeg"
    case leftFoot = "LeftFoot", rightFoot = "RightFoot"
    case spine = "Spine", chest = "Chest", neck = "Neck", head = "Head"
    case leftShoulder = "LeftShoulder", rightShoulder = "RightShoulder"
    case leftUpperArm = "LeftUpperArm", rightUpperArm = "RightUpperArm"
    case leftLowerArm = "LeftLowerArm", rightLowerArm = "RightLowerArm"
    case leftHand = "LeftHand", rightHand = "RightHand"
    case leftToes = "LeftToes", rightToes = "RightToes"
    case leftEye = "LeftEye", rightEye = "RightEye"
    case jaw = "Jaw"
    case leftThumbProximal = "LeftThumbProximal", leftThumbIntermediate = "LeftThumbIntermediate", leftThumbDistal = "LeftThumbDistal"
    case leftIndexProximal = "LeftIndexProximal", leftIndexIntermediate = "LeftIndexIntermediate", leftIndexDistal = "LeftIndexDistal"
    case leftMiddleProximal = "LeftMiddleProximal", leftMiddleIntermediate = "LeftMiddleIntermediate", leftMiddleDistal = "LeftMiddleDistal"
    case leftRingProximal = "LeftRingProximal", leftRingIntermediate = "LeftRingIntermediate", leftRingDistal = "LeftRingDistal"
    case leftLittleProximal = "LeftLittleProximal", leftLittleIntermediate = "LeftLittleIntermediate", leftLittleDistal = "LeftLittleDistal"
    case rightThumbProximal = "RightThumbProximal", rightThumbIntermediate = "RightThumbIntermediate", rightThumbDistal = "RightThumbDistal"
    case rightIndexProximal = "RightIndexProximal", rightIndexIntermediate = "RightIndexIntermediate", rightIndexDistal = "RightIndexDistal"
    case rightMiddleProximal = "RightMiddleProximal", rightMiddleIntermediate = "RightMiddleIntermediate", rightMiddleDistal = "RightMiddleDistal"
    case rightRingProximal = "RightRingProximal", rightRingIntermediate = "RightRingIntermediate", rightRingDistal = "RightRingDistal"
    case rightLittleProximal = "RightLittleProximal", rightLittleIntermediate = "RightLittleIntermediate", rightLittleDistal = "RightLittleDistal"
    case upperChest = "UpperChest"

    /// 보내는 이름 (`/VMC/Ext/Bone/Pos`의 첫 인자)
    public var name: String { rawValue }

    /// 얼굴이 보내는 뼈 (Head, LeftEye, RightEye). 몸으로는 보내지 않는다
    public var isFace: Bool {
        self == .head || self == .leftEye || self == .rightEye
    }

    /// 손가락 마디 (기능 hands)
    public var isFinger: Bool {
        rawValue.hasSuffix("Proximal") || rawValue.hasSuffix("Intermediate") || rawValue.hasSuffix("Distal")
    }
}

/// 몸 한 프레임 (v1.1, docs/face-link.md 3.2): 뼈마다 부모 뼈 기준 로컬 회전.
/// 좌표는 VMC(Unity: 왼손 좌표계, +Y 위, +Z 앞)이고, 정규화한 T 자세(팔을 옆으로 편 자세, 모든 뼈가 같은 방향)가 단위 회전이다.
/// 사용자 기준 좌우다 (LeftUpperArm = 사용자의 왼팔). 보이는 뼈만 넣는다 (받는 쪽은 안 온 뼈를 지난 값으로 둔다)
public struct BodyPose: Sendable {
    public var bones: [HumanBone: simd_quatf]
    /// 몸 전체 방향 (`/VMC/Ext/Root/Pos`). nil이면 보내지 않는다
    public var root: simd_quatf?

    public init(bones: [HumanBone: simd_quatf] = [:], root: simd_quatf? = nil) {
        self.bones = bones
        self.root = root
    }
}
