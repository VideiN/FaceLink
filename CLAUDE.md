# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트

Face Link: 아이폰 TrueDepth 얼굴 추적 수치(블렌드셰이프 52개, 머리·눈 자세)를 UDP/OSC(VMC 호환, FaceLink v1)로 아이패드의 Broadcast 앱에 보내는 컴패니언 앱. **설계와 프로토콜의 기준은 `docs/face-link.md`**다. 기능을 만들기 전에 읽는다.

- 받는 쪽 Broadcast는 다른 저장소다 (`VideiN/iPadOS-broadcasting`, `face-link` 브랜치, GPL). 두 앱은 프로토콜로만 연결된다. **Broadcast의 코드를 이 저장소에 가져오지 않는다** (이 저장소는 MIT). 참고로 읽는 것은 된다 (`gh api repos/VideiN/iPadOS-broadcasting/contents/<경로>?ref=face-link`)
- 프로토콜을 바꾸면 `/FaceLink/Hello`의 버전을 올리고, 두 저장소의 `docs/face-link.md`를 함께 고친다 (FaceLinkKit의 상수도)
- 의존성은 Apple 프레임워크만 쓴다 (OSC 인코더도 직접 만든다)

## 빌드와 시험

사용자는 Windows만 쓰고 Mac이 없다. **빌드는 GitHub Actions(`.github/workflows/ios.yml`, `macos-26` 러너)에서만 된다.** 이 PC에서는 Swift를 컴파일할 수 없으므로, push한 뒤 CI 결과로 확인한다 (`gh run watch`, `gh run view --log-failed`).

- 잡 `simulator`: 수신기 시험(`python3 -m unittest discover -s scripts -v`) → `swift test --package-path FaceLinkKit` → 시뮬레이터용 빌드 → `scripts/ci-run-simulator.sh`: 파이썬 수신기를 띄우고 앱을 `-autotest-send 127.0.0.1:39539`로 띄워 시험 송신을 받는다. 수신기가 형식·Ack·Calibrate를, 스크립트가 앱 로그(`build: #<실행 번호> `, `sender: …`)를 확인한다. 로그·수신기 결과·스크린숏은 아티팩트 `app-simulator-run`
- 잡 `ipa`: 기기용 빌드 → 가짜 서명 IPA, 아티팩트 `facelink-ipa-<실행 번호>`. 사용자는 LiveContainer로 설치한다
- Mac에서라면: `bash scripts/install-xcodegen.sh`, `bash scripts/build.sh simulator|device`, `swift test --package-path FaceLinkKit --filter <시험 이름>`
- `FaceLink.xcodeproj`는 저장소에 없다. `project.yml`(XcodeGen)에서 `scripts/build.sh`가 매번 만든다. 파일·설정을 더하면 `project.yml`을 고친다
- Python 스크립트는 이 PC에서도 돌릴 수 있다: `python -m unittest discover -s scripts -v`. `scripts/facelink_receiver.py`는 PC에서 실기기가 보내는 값을 보는 데도 쓴다 (인자 없이 실행)

## 구조

- `FaceLinkKit/`: 로컬 Swift 패키지, Swift 6 언어 모드. UI·ARKit과 상관없는 것은 모두 여기 둔다: OSC 인코딩·디코딩, FaceLink 메시지와 프레임 나누기, 좌표 변환·정면 보정, 보낼 곳(`FaceLinkTarget`), 보내는 쪽(`FaceLinkSender`, Network.framework), 시험 송신용 합성 얼굴. macOS에서 `swift test`로 시뮬레이터 없이 시험한다 (보내는 쪽은 루프백 UDP 소켓으로)
- `FaceLinkSender`와 얼굴 공급원(`FaceFrameSource`)은 자기 DispatchQueue에서만 상태를 만지는 `@unchecked Sendable` 클래스다. 정면 보정도 보내는 쪽이 한다 (보내는 값이 보정 뒤 값이므로). 화면은 `currentStatus`를 1초마다 읽는다
- `FaceLink/`: 앱 (SwiftUI). 기본 격리가 `MainActor`다 (`SWIFT_DEFAULT_ACTOR_ISOLATION`). ARKit 콜백처럼 메인 밖에서 도는 코드는 `nonisolated`를 붙인다. 로그는 `log()`(표준 출력)이고, CI가 줄을 찾으므로 로그 문구를 바꾸면 `scripts/ci-run-simulator.sh`도 고친다
- 빌드 정보: `scripts/build.sh`가 CI 실행 번호를 버전 `0.1.<번호>`와 빌드 설정 `FACELINK_BUILD_*`로 넘기고 → `FaceLink/Info.plist`의 `FaceLinkBuild` → `BuildInfo.swift`. 설치한 앱이 어느 빌드인지 기기에서 보이게 하려는 것이다 (설계 문서 4.3)
- 시뮬레이터에서는 ARKit 얼굴 추적이 안 된다. 그래서 시험 송신 모드(합성 얼굴)로 CI에서 보내기를 끝까지 확인한다. 실행 인자는 `AppModel.runAutoTest`

## 정해진 것

- 번들 ID `io.github.videin.facelink`, 앱 이름 "Face Link", 아이폰 전용, 최소 iOS 26.0. 사용자 기기는 iPhone 18 Pro Max, iOS 27이다. `macos-26` 러너의 Xcode(26.6)로 빌드할 수 있게 26.0으로 두었다. Xcode 27 러너(`xcode-27`)는 아직 미리보기다
- 사용자와는 한국어로 소통하고, 앱 화면 문구도 한국어다. 문서·주석은 설계 문서처럼 쉬운 한국어로 쓴다
- 커밋은 Broadcast 저장소와 같게: 한국어 제목 한 줄, 본문에 사용자 요청(인용)과 바뀐 점, 끝에 Co-Authored-By

## 작업 기록과 계획

- `worklog/`에 마크다운으로 남긴다. **git에 올리지 않는다** (`.gitignore`). 이 PC에만 있다
- `worklog/plan.md`: 단계별 작업 계획과 상태. 단계를 시작하거나 끝내면 고친다
- `worklog/<날짜>.md`: 그날 한 일. 작업이 끝날 때마다 사용자 요청, 결정, 한 일, 확인 결과(CI 실행 번호, 커밋), 남은 일을 덧붙인다
