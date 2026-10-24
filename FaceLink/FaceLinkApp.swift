import SwiftUI

@main
struct FaceLinkApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        log("build: \(BuildInfo.current.summary) (version \(BuildInfo.current.version))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    model.runAutoTest(arguments: ProcessInfo.processInfo.arguments)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // 뒤로 가면 ARKit이 멈춘다 (기록에서 보이게)
            log("app: \(phase)")
        }
    }
}
