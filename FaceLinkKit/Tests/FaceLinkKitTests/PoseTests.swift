import Foundation
import Testing
import simd
@testable import FaceLinkKit

private func degrees(_ value: Float) -> Float {
    value * .pi / 180
}

private func yaw(_ angle: Float) -> simd_quatf {
    simd_quatf(angle: degrees(angle), axis: SIMD3(0, 1, 0))
}

private func pitch(_ angle: Float) -> simd_quatf {
    simd_quatf(angle: degrees(angle), axis: SIMD3(1, 0, 0))
}

/// q와 −q는 같은 회전
func isClose(_ a: simd_quatf, _ b: simd_quatf, tolerance: Float = 1e-5) -> Bool {
    abs(simd_dot(a, b)) > 1 - tolerance
}

func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-5) -> Bool {
    simd_length(a - b) < tolerance
}

private func matrix(_ pose: Pose) -> simd_float4x4 {
    var matrix = simd_float4x4(pose.rotation)
    matrix.columns.3 = SIMD4(pose.position, 1)
    return matrix
}

@Test func poseFromTransformMatrix() {
    let rotation = yaw(30) * pitch(-10)
    var matrix = simd_float4x4(rotation)
    matrix.columns.3 = SIMD4(0.1, -0.2, -0.4, 1)
    let pose = Pose(matrix)
    #expect(isClose(pose.position, SIMD3(0.1, -0.2, -0.4)))
    #expect(isClose(pose.rotation, rotation))
}

@Test func poseInverseAndComposition() {
    let a = Pose(position: SIMD3(0.1, 0.2, -0.3), rotation: yaw(40) * pitch(15))
    let b = Pose(position: SIMD3(-0.05, 0, 0.02), rotation: pitch(-20))
    let identity = a.inverse * a
    #expect(isClose(identity.position, .zero))
    #expect(isClose(identity.rotation, Pose.identity.rotation))
    // 행렬 곱과 같은 결과
    let product = Pose(matrix(a) * matrix(b))
    let composed = a * b
    #expect(isClose(composed.position, product.position))
    #expect(isClose(composed.rotation, product.rotation))
}

/// 아이폰을 비스듬히 둬도, 보정한 순간의 자세가 기준(회전 0, 위치 0)이 된다
@Test func calibrationMakesReferencePoseZero() {
    let reference = Pose(position: SIMD3(0.15, -0.05, -0.35), rotation: yaw(35) * pitch(-12))
    var calibration = HeadCalibration()
    #expect(calibration.apply(to: reference) == reference)

    calibration.setReference(reference)
    let atReference = calibration.apply(to: reference)
    #expect(isClose(atReference.position, .zero))
    #expect(isClose(atReference.rotation, Pose.identity.rotation))

    // 기준에서 머리만 오른쪽으로 20도 돌리면, 보정 뒤 값은 정확히 그 20도 (아이폰 각도와 상관없이)
    let turned = reference * Pose(position: .zero, rotation: yaw(-20))
    let relative = calibration.apply(to: turned)
    #expect(isClose(relative.rotation, yaw(-20)))
    #expect(isClose(relative.position, .zero))

    calibration.reset()
    #expect(calibration.apply(to: turned) == turned)
}

/// 위치 (x, y, −z), 쿼터니언 (−qx, −qy, qz, qw): Z축을 뒤집은 공간에서 같은 회전이어야 한다
@Test func unityConversionMirrorsZ() {
    let flip = SIMD3<Float>(1, 1, -1)
    #expect(UnityCoordinates.position(SIMD3(1, 2, 3)) == SIMD3(1, 2, -3))
    let rotations = [yaw(30), pitch(-45), simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3<Float>(0.3, -0.5, 0.8)))]
    let vectors: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0.2, -0.7, 0.4)]
    for rotation in rotations {
        let unity = UnityCoordinates.rotation(rotation)
        for vector in vectors {
            #expect(isClose(unity.act(vector * flip), rotation.act(vector) * flip))
        }
    }
    let q = simd_quatf(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9)
    let converted = UnityCoordinates.rotation(q)
    #expect(converted.vector == SIMD4(-0.1, -0.2, 0.3, 0.9))
}
