import FaceLinkKit
import SwiftUI

struct ContentView: View {
    private let build = BuildInfo.current

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "face.dashed")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Face Link")
                .font(.largeTitle.bold())
            Text("아이폰 얼굴 추적 → 아이패드 Broadcast")
                .foregroundStyle(.secondary)
            Text("FaceLink v\(FaceLinkProtocol.version) · 포트 \(String(FaceLinkProtocol.defaultPort)) · 블렌드셰이프 \(BlendShape.allCases.count)개")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer().frame(height: 24)
            Text("빌드 \(build.summary) · \(build.version)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
