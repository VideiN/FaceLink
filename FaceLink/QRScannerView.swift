import AVFoundation
import FaceLinkKit
import SwiftUI
import VisionKit

/// 아이패드 화면의 QR(facelink://…)을 찍는 시트 (docs/face-link.md 3.4)
struct QRScannerSheet: View {
    let onTarget: (FaceLinkTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraReady: Bool?
    @State private var message: String?

    static var isSupported: Bool {
        DataScannerViewController.isSupported
    }

    var body: some View {
        NavigationStack {
            Group {
                switch cameraReady {
                case nil:
                    ProgressView()
                case true?:
                    QRScannerView(onPayload: handle)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text(message ?? "아이패드 Broadcast의 Face Link QR을 화면에 맞춰 주세요.")
                                .font(.callout)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.bottom, 32)
                        }
                case false?:
                    ContentUnavailableView(
                        "카메라를 쓸 수 없습니다",
                        systemImage: "camera.fill",
                        description: Text("설정 › Face Link에서 카메라를 켜 주세요. IP:포트를 직접 넣어도 됩니다.")
                    )
                }
            }
            .navigationTitle("QR 코드 찍기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraReady = granted && DataScannerViewController.isAvailable
        }
    }

    private func handle(_ payload: String) {
        do {
            let target = try FaceLinkTarget(url: payload)
            log("qr: \(target.addressDescription) (\(target.name))")
            onTarget(target)
            dismiss()
        } catch {
            message = error.message
        }
    }
}

extension TargetURLError {
    var message: String {
        switch self {
        case .notFaceLink: "Face Link QR이 아닙니다."
        case .unsupportedVersion(let version): "이 앱과 프로토콜 버전이 다릅니다 (v\(version)). 두 앱을 최신으로 맞춰 주세요."
        case .invalidAddress: "QR의 주소를 읽지 못했습니다."
        }
    }
}

/// VisionKit DataScannerViewController로 QR만 읽는다
private struct QRScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onPayload(payload)
                    return
                }
            }
        }
    }
}
