import simd

/// 위치(미터)와 회전
public struct Pose: Sendable {
    public var position: SIMD3<Float>
    public var rotation: simd_quatf

    public static let identity = Pose(position: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))

    public init(position: SIMD3<Float>, rotation: simd_quatf) {
        self.position = position
        self.rotation = rotation
    }

    /// 크기 변환이 없는 4×4 변환 행렬에서 (ARKit의 transform)
    public init(_ transform: simd_float4x4) {
        let translation = transform.columns.3
        position = SIMD3(translation.x, translation.y, translation.z)
        rotation = simd_quatf(transform).normalized
    }

    public var inverse: Pose {
        let inverseRotation = rotation.inverse
        return Pose(position: inverseRotation.act(-position), rotation: inverseRotation)
    }

    /// 변환을 이어 붙인다. `a * b`는 b를 a의 좌표계 안에 놓은 것 (행렬 곱과 같은 순서)
    public static func * (a: Pose, b: Pose) -> Pose {
        Pose(position: a.position + a.rotation.act(b.position), rotation: (a.rotation * b.rotation).normalized)
    }
}

extension Pose: Equatable {
    public static func == (a: Pose, b: Pose) -> Bool {
        a.position == b.position && a.rotation.vector == b.rotation.vector
    }
}

/// 얼굴 한 프레임. ARKit 좌표(오른손 좌표계, +Y 위, 단위 미터)이고, 사용자 기준이다 (EyeBlinkLeft = 사용자의 왼쪽 눈)
public struct FaceFrame: Sendable {
    /// false면 얼굴을 놓친 프레임. 나머지 값은 쓰지 않는다
    public var isTracked: Bool
    /// 없는 이름은 0으로 보낸다
    public var blendShapes: [BlendShape: Float]
    /// 머리 자세: 카메라 기준 (`camera.transform⁻¹ × faceAnchor.transform`)
    public var head: Pose
    /// 눈 방향: 머리 기준 (`ARFaceAnchor.leftEyeTransform`·`rightEyeTransform`의 회전). 없으면 보내지 않는다
    public var leftEye: simd_quatf?
    public var rightEye: simd_quatf?

    public init(
        isTracked: Bool = true,
        blendShapes: [BlendShape: Float] = [:],
        head: Pose = .identity,
        leftEye: simd_quatf? = nil,
        rightEye: simd_quatf? = nil
    ) {
        self.isTracked = isTracked
        self.blendShapes = blendShapes
        self.head = head
        self.leftEye = leftEye
        self.rightEye = rightEye
    }

    public static let lost = FaceFrame(isTracked: false)
}

/// 정면 보정 (docs/face-link.md 3.2): 사용자가 정면을 본다고 누른 순간의 머리 자세를 기준(회전 0, 위치 0)으로 삼아
/// 그 기준에서 달라진 만큼만 보낸다. 아이폰을 비스듬히 둬도 정면을 보면 회전이 0이 된다.
public struct HeadCalibration: Sendable, Equatable {
    public private(set) var reference: Pose?

    public init(reference: Pose? = nil) {
        self.reference = reference
    }

    public mutating func setReference(_ pose: Pose) {
        reference = pose
    }

    public mutating func reset() {
        reference = nil
    }

    /// 기준 머리의 좌표계로 본 지금 자세 (`reference⁻¹ × pose`). 기준이 없으면 그대로
    public func apply(to pose: Pose) -> Pose {
        guard let reference else { return pose }
        return reference.inverse * pose
    }
}

/// ARKit(오른손 좌표계) → VMC(Unity, 왼손 좌표계, +Y 위, +Z 앞) (docs/face-link.md 3.2)
public enum UnityCoordinates {
    /// (x, y, −z)
    public static func position(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(p.x, p.y, -p.z)
    }

    /// (−qx, −qy, qz, qw)
    public static func rotation(_ q: simd_quatf) -> simd_quatf {
        simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: q.imag.z, r: q.real)
    }
}
