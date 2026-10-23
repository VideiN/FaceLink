import SwiftUI

@main
struct FaceLinkApp: App {
    @State private var model = AppModel()

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
    }
}
