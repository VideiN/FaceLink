import SwiftUI

/// 최근 앱 로그 보기와 공유 (실기기 시험에서 무슨 일이 있었는지 보내 받으려고)
struct LogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "기록이 없습니다." : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle("기록")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem {
                Button("새로고침", systemImage: "arrow.clockwise", action: reload)
            }
            ToolbarItem {
                ShareLink(item: "Face Link \(BuildInfo.current.summary) · \(BuildInfo.current.version)\n\n\(text)")
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        text = AppLog.shared.text
    }
}
