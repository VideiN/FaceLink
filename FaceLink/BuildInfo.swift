import Foundation

/// 이 앱이 어느 CI 실행에서 나왔는지. 설치한 앱이 어느 빌드인지 기기에서 바로 알아보게 한다 (docs/face-link.md 4.3).
/// 값은 scripts/build.sh가 빌드 설정으로 넘기고, Info.plist의 FaceLinkBuild에 들어간다.
struct BuildInfo {
    static let current = BuildInfo(bundle: .main)

    /// GitHub Actions 실행 번호 (Actions 목록의 "#번호"). 로컬 빌드는 0
    let run: Int
    let branch: String
    let commit: String
    /// CFBundleShortVersionString. CI 빌드는 "0.1.<실행 번호>"라 LiveContainer 목록에서도 보인다
    let version: String

    init(bundle: Bundle) {
        let build = bundle.object(forInfoDictionaryKey: "FaceLinkBuild") as? [String: String] ?? [:]
        run = Int(build["Run"] ?? "") ?? 0
        branch = build["Branch"] ?? ""
        commit = String((build["Commit"] ?? "").prefix(7))
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// "#12 main 1a2b3c4". CI는 로그의 "build: #<실행 번호> "로 이 빌드가 떴는지 확인한다
    var summary: String {
        run > 0 ? "#\(run) \(branch) \(commit)" : "로컬 빌드"
    }
}
