/// FaceLink v1의 고정 값 (docs/face-link.md 3장). 바꾸면 Broadcast 저장소의 같은 문서도 함께 고친다.
public enum FaceLinkProtocol {
    /// `/FaceLink/Hello`의 첫 인자. v1.1(몸 뼈, 기능 인자, 소리 패킷)도 v1과 호환이라 "1" 그대로다
    public static let version = "1"
    /// 받는 쪽 기본 포트 (VMC와 같음)
    public static let defaultPort: UInt16 = 39539
    /// 받는 쪽(아이패드)이 알리는 Bonjour 서비스
    public static let bonjourServiceType = "_facelink._udp"
    /// UDP 데이터그램 하나의 최대 크기. 넘으면 IP 조각이 생긴다 (3.1)
    public static let maxDatagramSize = 1400
    /// 소리 패킷의 표본률 (3.8, 48 kHz 권장)
    public static let audioSampleRate: UInt32 = 48000
    /// 소리 패킷 하나의 표본 수 (48 kHz에서 10ms)
    public static let audioFramesPerPacket = 480

    /// OSC 주소 (3.2, 3.3, 3.5)
    public enum Address {
        public static let hello = "/FaceLink/Hello"
        public static let frame = "/FaceLink/Frame"
        public static let ack = "/FaceLink/Ack"
        public static let calibrate = "/FaceLink/Calibrate"
        public static let blendValue = "/VMC/Ext/Blend/Val"
        public static let blendApply = "/VMC/Ext/Blend/Apply"
        public static let bonePosition = "/VMC/Ext/Bone/Pos"
        /// v1.1: 몸 전체 방향
        public static let rootPosition = "/VMC/Ext/Root/Pos"
    }
}

/// Hello의 여섯째 인자 "기능" (v1.1, 3.3): 지금 보내는 것
public enum FaceLinkFeature: String, CaseIterable, Sendable {
    case face
    /// 몸 뼈
    case body
    /// 손가락 뼈
    case hands
    /// 소리 패킷 (3.8)
    case audio

    /// "face,body,hands,audio"처럼 쉼표로 (늘 이 순서)
    public static func list(_ features: Set<FaceLinkFeature>) -> String {
        allCases.filter(features.contains).map(\.rawValue).joined(separator: ",")
    }
}
