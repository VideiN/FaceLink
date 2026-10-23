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
                    Button(model.isSending ? "멈추기" : "시험 송신 시작") {
                        if model.isSending {
                            model.stop()
                        } else {
                            model.startTestSend()
                        }
                    }
                    .disabled(!model.isSending && model.target == nil)
                    Button("정면 맞추기") {
                        model.calibrate()
                    }
                    .disabled(!model.isSending)
                } header: {
                    Text("시험 송신")
                } footer: {
                    Text("얼굴 없이 합성 값(눈 깜빡임, 입 벌림, 머리 좌우)을 보냅니다.")
                }

                if model.isSending {
                    StatusSection(status: model.status)
                }

                Section("정보") {
                    LabeledContent("빌드", value: "\(build.summary) · \(build.version)")
                    LabeledContent("프로토콜", value: "FaceLink v\(FaceLinkProtocol.version) · 기본 포트 \(String(FaceLinkProtocol.defaultPort))")
                }
            }
            .navigationTitle("Face Link")
        }
    }
}

struct StatusSection: View {
    let status: FaceLinkSender.Status

    var body: some View {
        Section("상태") {
            LabeledContent("보내는 속도", value: "\(status.sendFPS) fps")
            LabeledContent("받는 쪽", value: receiverText)
            if let roundTrip = status.roundTrip, status.isResponding {
                LabeledContent("왕복 지연", value: "\(Int(roundTrip * 1000)) ms")
            }
            LabeledContent("정면 보정", value: status.isCalibrated ? "함" : "안 함")
            if let problem = status.problem {
                Text(problem.message)
                    .foregroundStyle(.red)
            }
        }
    }

    private var receiverText: String {
        guard let ack = status.lastAck else { return "기다리는 중" }
        guard status.isResponding else { return "응답 없음" }
        return "\(ack.receiverName) · \(Int(ack.receiverFPS.rounded())) fps"
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
