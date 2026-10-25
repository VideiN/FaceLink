import FaceLinkKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    private let build = BuildInfo.current

    var body: some View {
        NavigationStack {
            Form {
                Section("보낼 곳") {
                    NavigationLink {
                        TargetPickerView(model: model)
                    } label: {
                        if let target = model.target {
                            TargetRow(title: target.name, detail: target.addressDescription)
                        } else {
                            Text("보낼 곳 고르기")
                        }
                    }
                    .disabled(model.isSending)
                }

                Section {
                    if model.isSending {
                        Button(calibrationTitle) {
                            model.calibrate()
                        }
                        .disabled(model.calibrationCountdown != nil)
                        Button("멈추기", role: .destructive) {
                            model.stop()
                        }
                    } else {
                        Button("얼굴 추적 보내기 시작") {
                            model.start(.face)
                        }
                        .disabled(model.target == nil || !AppModel.isFaceTrackingSupported)
                        Button("시험 송신 시작") {
                            model.start(.test)
                        }
                        .disabled(model.target == nil)
                    }
                } header: {
                    Text("보내기")
                } footer: {
                    Text(sendFooter)
                }

                if model.isSending {
                    StatusSection(model: model)
                }

                Section {
                    Picker("보내는 속도", selection: $model.frameRate) {
                        Text("60Hz").tag(60)
                        Text("30Hz").tag(30)
                    }
                    Toggle("눈 방향 보내기", isOn: $model.sendEyes)
                    Toggle("머리 위치 보내기", isOn: $model.sendHeadPosition)
                } header: {
                    Text("설정")
                } footer: {
                    Text("30Hz는 발열과 배터리를 줄입니다. 보내는 동안에는 바꿀 수 없습니다.")
                }
                .disabled(model.isSending)

                Section("정보") {
                    LabeledContent("빌드", value: "\(build.summary) · \(build.version)")
                    LabeledContent("프로토콜", value: "FaceLink v\(FaceLinkProtocol.version) · 기본 포트 \(String(FaceLinkProtocol.defaultPort))")
                    NavigationLink("기록") {
                        LogView()
                    }
                }
            }
            .navigationTitle("Face Link")
        }
    }

    private var calibrationTitle: String {
        if let remaining = model.calibrationCountdown {
            return "정면을 보세요… \(remaining)"
        }
        return "정면 맞추기 (\(AppModel.calibrationDelay)초 뒤)"
    }

    private var sendFooter: String {
        if model.isSending {
            return "정면 맞추기를 누르고 \(AppModel.calibrationDelay)초 안에 정면(방송 화면 쪽)을 보세요. 다른 앱으로 가거나 화면이 꺼지면 얼굴 추적이 멈춥니다."
        }
        if !AppModel.isFaceTrackingSupported {
            return "이 기기는 얼굴 추적을 지원하지 않습니다 (Face ID가 있는 아이폰이 필요합니다). 시험 송신은 얼굴 없이 합성 값(눈 깜빡임, 입 벌림, 머리 좌우)을 보냅니다."
        }
        return "얼굴 추적은 앱을 앞에 켜 둔 동안만 됩니다. 시험 송신은 얼굴 없이 합성 값(눈 깜빡임, 입 벌림, 머리 좌우)을 보냅니다."
    }
}

struct StatusSection: View {
    let model: AppModel

    private var status: FaceLinkSender.Status { model.status }

    var body: some View {
        Section("상태") {
            LabeledContent("얼굴", value: faceText)
            LabeledContent("보내는 속도", value: "\(status.sendFPS) fps")
            LabeledContent("받는 쪽", value: receiverText)
            if let roundTrip = status.roundTrip, status.isResponding {
                LabeledContent("왕복 지연", value: "\(Int(roundTrip * 1000)) ms")
            }
            LabeledContent("정면 보정", value: status.isCalibrated ? "함" : "안 함")
            if let message = model.faceState?.message {
                Text(message)
                    .foregroundStyle(.red)
            }
            if let problem = status.problem {
                Text(problem.message)
                    .foregroundStyle(.red)
            }
            if let hint = noResponseHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 3초 넘게 Ack가 없을 때 할 일 (docs/face-link.md 3.6). 받는 쪽은 토큰이 빈 Hello(Bonjour·직접 입력)를
    /// "연결 요청"으로 보이고 사용자가 허락해야 받는다. 틀린 토큰(예전 QR)은 버린다
    private var noResponseHint: String? {
        guard !status.isResponding, status.problem == nil, status.framesSent >= model.frameRate * 3 else { return nil }
        if model.target?.token.isEmpty ?? true {
            return "아이패드의 Broadcast에 뜬 연결 요청을 허락하거나, 아이패드의 QR을 찍어 주세요."
        }
        return "아이패드가 응답하지 않습니다. 아이패드에서 페어링 코드를 다시 만들었다면 QR을 다시 찍어 주세요."
    }

    private var faceText: String {
        switch model.mode {
        case .test: "시험 송신 (합성 값)"
        case .face: status.framesSent == 0 ? "시작하는 중" : (status.isTracking ? "추적 중" : "얼굴을 찾는 중")
        case nil: ""
        }
    }

    private var receiverText: String {
        guard let ack = status.lastAck else { return "기다리는 중" }
        guard status.isResponding else { return "응답 없음" }
        return "\(ack.receiverName) · \(Int(ack.receiverFPS.rounded())) fps"
    }
}

extension ARKitFaceSource.State {
    /// 문제일 때만 문구
    var message: String? {
        switch self {
        case .running: nil
        case .interrupted: "얼굴 추적이 잠시 멈췄습니다. 다른 앱이 카메라를 쓰고 있거나 앱이 뒤로 갔습니다."
        case .cameraDenied: "카메라 권한이 꺼져 있습니다. 설정 › Face Link에서 카메라를 켜 주세요."
        case .failed(let description): "얼굴 추적 오류: \(description)"
        }
    }
}

extension NetworkProblem {
    var message: String {
        switch self {
        case .localNetworkDenied:
            "로컬 네트워크 권한이 꺼져 있습니다. 설정 › 개인정보 보호 및 보안 › 로컬 네트워크에서 Face Link를 켜 주세요."
        case .receiverNotListening:
            "받는 쪽이 받고 있지 않습니다. 아이패드의 Broadcast에서 얼굴 추적을 켰는지, 주소와 포트가 맞는지 확인해 주세요."
        case .network(let description):
            "네트워크 오류: \(description)"
        }
    }
}

#Preview {
    ContentView(model: AppModel())
}
