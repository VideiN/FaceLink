#!/bin/bash
# 앱을 빌드하고 ad-hoc(가짜) 서명한다. Xcode가 있는 macOS에서만 돈다 (이 저장소는 GitHub Actions에서 빌드한다).
#   scripts/build.sh simulator   시뮬레이터용 (Debug)
#   scripts/build.sh device      기기용 (Release). 기기에는 LiveContainer가 다시 서명해 설치한다
# 만든 .app 경로를 표준 출력의 마지막 줄로 알려 준다 (빌드 기록은 표준 오류로).
# GitHub Actions에서는 실행 번호를 버전(0.1.<번호>)과 빌드 정보(Info.plist의 FaceLinkBuild)에 넣는다.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  simulator) sdk=iphonesimulator; destination='generic/platform=iOS Simulator'; configuration=Debug ;;
  device) sdk=iphoneos; destination='generic/platform=iOS'; configuration=Release ;;
  *) echo "usage: $0 simulator|device" >&2; exit 2 ;;
esac

run=${GITHUB_RUN_NUMBER:-0}
branch=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}}
commit=${GITHUB_SHA:-$(git rev-parse HEAD)}

xcodegen generate --quiet >&2

# 서명은 Xcode에 맡기지 않는다: 개발자 팀 없이 기기용으로 빌드하려면 서명을 꺼야 한다
xcodebuild -quiet \
  -project FaceLink.xcodeproj -scheme FaceLink \
  -configuration "$configuration" -sdk "$sdk" -destination "$destination" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="0.1.$run" CURRENT_PROJECT_VERSION="$run" \
  FACELINK_BUILD_RUN="$run" FACELINK_BUILD_BRANCH="$branch" FACELINK_BUILD_COMMIT="$commit" \
  build >&2

app="build/DerivedData/Build/Products/$configuration-$sdk/FaceLink.app"
codesign --force --sign - --timestamp=none "$app" >&2
echo "$app"
