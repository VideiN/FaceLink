# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트

Face Link: 아이폰 TrueDepth 얼굴 추적 수치(블렌드셰이프 52개, 머리·눈 자세)를 UDP/OSC(VMC 호환, FaceLink v1)로 아이패드의 Broadcast 앱에 보내는 컴패니언 앱. **설계와 프로토콜의 기준은 `docs/face-link.md`**다. 기능을 만들기 전에 읽는다.

- 받는 쪽 Broadcast는 다른 저장소다 (`VideiN/iPadOS-broadcasting`, `face-link` 브랜치, GPL). 두 앱은 프로토콜로만 연결된다. **Broadcast의 코드를 이 저장소에 가져오지 않는다** (이 저장소는 MIT). 참고로 읽는 것은 된다 (`gh api repos/VideiN/iPadOS-broadcasting/contents/<경로>?ref=face-link`)
- 프로토콜을 바꾸면 `/FaceLink/Hello`의 버전을 올리고, 두 저장소의 `docs/face-link.md`를 함께 고친다 (FaceLinkKit의 상수도)
- 의존성은 Apple 프레임워크만 쓴다 (OSC 인코더도 직접 만든다)

## 빌드와 시험

사용자는 Windows만 쓰고 Mac이 없다. **빌드는 GitHub Actions(`.github/workflows/ios.yml`, `macos-26` 러너)에서만 된다.** 이 PC에서는 Swift를 컴파일할 수 없으므로, push한 뒤 CI 결과로 확인한다 (`gh run watch`, `gh run view --log-failed`).

- 잡 `simulator`: `swift test --package-path FaceLinkKit` → 시뮬레이터용 빌드 → 아이폰 시뮬레이터에서 띄워 로그에 `build: #<실행 번호> `가 찍히는지 확인. 로그와 스크린숏은 아티팩트 `app-simulator-run`
- 잡 `ipa`: 기기용 빌드 → 가짜 서명 IPA, 아티팩트 `facelink-ipa-<실행 번호>`. 사용자는 LiveContainer로 설치한다
- Mac에서라면: `bash scripts/install-xcodegen.sh`, `bash scripts/build.sh simulator|device`, `swift test --package-path FaceLinkKit --filter <시험 이름>`
- `FaceLink.xcodeproj`는 저장소에 없다. `project.yml`(XcodeGen)에서 `scripts/build.sh`가 매번 만든다. 파일·설정을 더하면 `project.yml`을 고친다
- Python 스크립트는 이 PC에서도 돌릴 수 있다 (`python -I`)

## 구조

- `FaceLinkKit/`: 로컬 Swift 패키지. 프로토콜(상수, 블렌드셰이프 이름, 앞으로 OSC 인코딩·번들 나누기 등) 중 UI·ARKit·네트워크와 상관없는 순수 로직. macOS에서 `swift test`로 시뮬레이터 없이 시험하므로 시험할 수 있는 로직은 여기에 둔다. Swift 6 언어 모드
- `FaceLink/`: 앱 (SwiftUI). 기본 격리가 `MainActor`다 (`SWIFT_DEFAULT_ACTOR_ISOLATION`). ARKit 콜백·네트워크처럼 메인 밖에서 도는 코드는 `nonisolated`를 붙인다
- 빌드 정보: `scripts/build.sh`가 CI 실행 번호를 버전 `0.1.<번호>`와 빌드 설정 `FACELINK_BUILD_*`로 넘기고 → `FaceLink/Info.plist`의 `FaceLinkBuild` → `BuildInfo.swift`. 설치한 앱이 어느 빌드인지 기기에서 보이게 하려는 것이다 (설계 문서 4.3). CI는 앱이 시작할 때 찍는 `build: …` 줄로 확인한다
- 시뮬레이터에서는 ARKit 얼굴 추적이 안 된다. 그래서 설계 문서의 **시험 송신 모드**(합성 값 보내기)와 파이썬 수신기로 CI에서 형식을 확인할 계획이다 (4.3)

## 정해진 것

- 번들 ID `io.github.videin.facelink`, 앱 이름 "Face Link", 아이폰 전용, 최소 iOS 26.0. 사용자 기기는 iPhone 18 Pro Max, iOS 27이다. `macos-26` 러너의 Xcode(26.6)로 빌드할 수 있게 26.0으로 두었다. Xcode 27 러너(`xcode-27`)는 아직 미리보기다
- 사용자와는 한국어로 소통하고, 앱 화면 문구도 한국어다. 문서·주석은 설계 문서처럼 쉬운 한국어로 쓴다
- 커밋은 Broadcast 저장소와 같게: 한국어 제목 한 줄, 본문에 사용자 요청(인용)과 바뀐 점, 끝에 Co-Authored-By
