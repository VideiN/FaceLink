import SwiftUI

@main
struct FaceLinkApp: App {
    init() {
        print("build: \(BuildInfo.current.summary) (version \(BuildInfo.current.version))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
