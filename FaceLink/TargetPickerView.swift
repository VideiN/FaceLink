import FaceLinkKit
import SwiftUI

/// 보낼 곳 고르기 (docs/face-link.md 3.4): Bonjour 목록, QR, IP:포트 직접 입력, 마지막으로 연결한 곳.
/// LiveContainer 안에서는 Bonjour가 막힐 수 있어 QR·직접 입력만으로도 끝까지 쓸 수 있게 한다
struct TargetPickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var addressText = ""
    @State private var addressError = false
    @State private var showingScanner = false

    var body: some View {
        Form {
            Section {
                ForEach(model.services) { service in
                    Button {
                        choose(service.target)
                    } label: {
                        TargetRow(title: service.displayName, detail: service.version.map { "\(service.serviceName) · v\($0)" } ?? service.serviceName)
                    }
                }
                if model.services.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("찾는 중…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let problem = model.browseProblem {
                    Text(problem.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("같은 Wi-Fi의 아이패드")
            } footer: {
                Text("아이패드의 Broadcast에서 얼굴 추적을 켜면 여기에 보입니다. 목록이나 직접 입력으로 고르면 처음 보낼 때 아이패드에서 연결 요청을 허락해야 합니다. 안 보이면 QR이나 직접 입력을 쓰세요.")
            }

            if QRScannerSheet.isSupported {
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("QR 코드 찍기", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("아이패드 화면의 QR에는 페어링 토큰도 들어 있어 아이패드에서 허락하지 않아도 됩니다.")
                }
            }

            Section {
                TextField("192.168.0.10:39539", text: $addressText)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(chooseAddress)
                Button("이 주소로", action: chooseAddress)
                    .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                if addressError {
                    Text("주소를 읽지 못했습니다. IP:포트 꼴로 넣어 주세요. 포트를 빼면 \(String(FaceLinkProtocol.defaultPort))입니다.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("직접 입력")
            }

            if let last = model.lastTarget {
                Section("마지막으로 연결한 곳") {
                    Button {
                        choose(last)
                    } label: {
                        TargetRow(title: last.name, detail: last.addressDescription)
                    }
                }
            }
        }
        .navigationTitle("보낼 곳")
        .sheet(isPresented: $showingScanner) {
            QRScannerSheet(onTarget: choose)
        }
        .onAppear { model.startBrowsing() }
        .onDisappear { model.stopBrowsing() }
    }

    private func chooseAddress() {
        guard let target = FaceLinkTarget(urlOrAddress: addressText) else {
            addressError = true
            return
        }
        addressError = false
        choose(target)
    }

    private func choose(_ target: FaceLinkTarget) {
        model.choose(target)
        dismiss()
    }
}

struct TargetRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
