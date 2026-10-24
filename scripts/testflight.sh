#!/bin/bash
# TestFlight에 올린다 (CI의 testflight 작업, 2026-10-25). Broadcast 저장소에서 같은 저자가 쓴 것을 이 앱에 맞게 고쳤다.
# ipa 작업이 만든 가짜 서명 IPA를 배포 인증서와 App Store 프로필로 다시 서명해 App Store Connect에 올린다.
# 서명된 IPA는 아티팩트로 남기지 않는다 (공개 저장소). 인증서 이름(계정 주인 실명)과 팀 정보는 로그에 찍지 않는다.
#
# 환경 변수 (testflight 환경의 비밀값): APPLE_DIST_P12_BASE64, APPLE_DIST_P12_PASSWORD, APPLE_PROFILE_BASE64,
# ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8
# 사용법: testflight.sh <가짜 서명 IPA> [앱의 .entitlements]
#   Face Link는 엔타이틀먼트가 없어(ARKit·Bonjour·UDP에는 필요 없다) IPA만 준다. 그러면 App ID와 팀만 넣어 서명한다
# 같은 빌드 번호(CFBundleVersion = 실행 번호)가 이미 App Store Connect에 있으면 다시 올리지 않는다.
# 실패한 실행을 다시 돌릴 때를 위해서다 (같은 번호로는 다시 올릴 수 없다)
# GITHUB_OUTPUT이 있으면 bundle(번들 ID)과 build(CFBundleVersion)를 남긴다 (처리 확인 작업이 쓴다)

set -euo pipefail

ipa=$1
app_entitlements=${2:-}
scripts=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/testflight.XXXXXX")
keychain="$work/signing.keychain-db"
key_dir="$HOME/.appstoreconnect/private_keys"

cleanup() {
  security delete-keychain "$keychain" > /dev/null 2>&1 || true
  rm -rf "$work" "$key_dir"
}
trap cleanup EXIT

secrets=(APPLE_DIST_P12_BASE64 APPLE_DIST_P12_PASSWORD APPLE_PROFILE_BASE64 ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8)
missing=()
for name in "${secrets[@]}"; do
  [ -n "${!name:-}" ] || missing+=("$name")
done
# 비밀값이 하나도 없으면 (포크 등) 올리지 않고 끝낸다. 일부만 있으면 설정 실수라 실패로
if [ ${#missing[@]} -eq ${#secrets[@]} ]; then
  echo "::notice::TestFlight secrets are not set (testflight environment); not uploading"
  exit 0
fi
if [ ${#missing[@]} -gt 0 ]; then
  echo "::error::secrets missing in the testflight environment: ${missing[*]}"
  exit 1
fi
# App Store Connect API 키의 형식을 먼저 본다 (값은 찍지 않고 길이만). 앞뒤 공백·줄바꿈은 지운다
ASC_KEY_ID=$(printf '%s' "$ASC_KEY_ID" | tr -d '[:space:]')
ASC_ISSUER_ID=$(printf '%s' "$ASC_ISSUER_ID" | tr -d '[:space:]')
bad=0
if ! [[ $ASC_KEY_ID =~ ^[A-Z0-9]{10}$ ]]; then
  hint=""
  [[ $ASC_KEY_ID == *PRIVATE* ]] && hint="; it looks like the .p8 contents, which belong in ASC_KEY_P8"
  echo "::error::ASC_KEY_ID should be the 10-character key ID from App Store Connect > Users and Access > Integrations (it has ${#ASC_KEY_ID} characters$hint)"
  bad=1
fi
if ! [[ $ASC_ISSUER_ID =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
  echo "::error::ASC_ISSUER_ID should be the issuer ID (a UUID like 12345678-1234-1234-1234-123456789012; it has ${#ASC_ISSUER_ID} characters)"
  bad=1
fi
if [[ $ASC_KEY_P8 != *"BEGIN PRIVATE KEY"* ]]; then
  echo "::error::ASC_KEY_P8 should be the whole AuthKey_<key ID>.p8 file, including the BEGIN/END PRIVATE KEY lines"
  bad=1
fi
[ $bad -eq 0 ] || exit 1

# 1. 프로필: App Store용이고 이 앱의 App ID인지
profile="$work/profile.mobileprovision"
printf '%s' "$APPLE_PROFILE_BASE64" | base64 --decode > "$profile"
security cms -D -i "$profile" > "$work/profile.plist" 2> /dev/null || {
  echo "::error::APPLE_PROFILE_BASE64 is not a provisioning profile"
  exit 1
}
profile_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$work/profile.plist" 2> /dev/null; }
app_identifier=$(profile_value Entitlements:application-identifier || true)
team_id=$(profile_value Entitlements:com.apple.developer.team-identifier || true)
if [ "$(profile_value Entitlements:get-task-allow || true)" != "false" ] || profile_value ProvisionedDevices > /dev/null; then
  echo "::error::the provisioning profile is not an App Store (distribution) profile"
  exit 1
fi

mkdir -p "$work/ipa"
unzip -q "$ipa" -d "$work/ipa"
app=$(ls -d "$work"/ipa/Payload/*.app)
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist"; }
bundle_id=$(plist_value CFBundleIdentifier)
version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
if [ "$app_identifier" != "$team_id.$bundle_id" ]; then
  echo "::error::the provisioning profile is for another App ID (this app is $bundle_id)"
  exit 1
fi
echo "profile: App Store, $bundle_id, expires $(profile_value ExpirationDate || true)"

# 2. 엔타이틀먼트: 앱의 것(있으면) + 프로필의 앱 ID·팀. 앱이 쓰는 기능은 App ID에도 켜져 있어야 한다
entitlements="$work/entitlements.plist"
if [ -n "$app_entitlements" ]; then
  cp "$app_entitlements" "$entitlements"
else
  /usr/libexec/PlistBuddy -c "Clear dict" "$entitlements" > /dev/null
fi
/usr/libexec/PlistBuddy -c "Add :application-identifier string $app_identifier" \
  -c "Add :com.apple.developer.team-identifier string $team_id" -c "Add :get-task-allow bool false" "$entitlements"
if [ "$(profile_value Entitlements:beta-reports-active || true)" = "true" ]; then
  /usr/libexec/PlistBuddy -c "Add :beta-reports-active bool true" "$entitlements"
fi
for key in $([ -z "$app_entitlements" ] || /usr/libexec/PlistBuddy -c Print "$app_entitlements" | sed -nE 's/^ +([^ ]+) = .*/\1/p'); do
  if ! profile_value "Entitlements:$key" > /dev/null; then
    echo "::error::the App ID does not have $key (turn it on in the developer portal, then make the profile again)"
    exit 1
  fi
done

# 3. 인증서: 이 실행만 쓰는 키체인에 넣는다
keychain_password=$(openssl rand -hex 16)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
printf '%s' "$APPLE_DIST_P12_BASE64" | base64 --decode > "$work/dist.p12"
if ! security import "$work/dist.p12" -k "$keychain" -f pkcs12 -P "$APPLE_DIST_P12_PASSWORD" -T /usr/bin/codesign \
  > /dev/null 2>&1; then
  echo "::error::could not import the .p12 (check APPLE_DIST_P12_BASE64 and APPLE_DIST_P12_PASSWORD; make it with -legacy)"
  exit 1
fi
rm -f "$work/dist.p12"
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null 2>&1; then
  echo "::error::could not let codesign use the imported key"
  exit 1
fi
# shellcheck disable=SC2046
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Distribution/ { print $2; exit }')
if [ -z "$identity" ]; then
  echo "::error::no Apple Distribution certificate with its private key in the .p12"
  exit 1
fi
# 프로필이 이 인증서로 만들어졌는지 (프로필 안 인증서들의 SHA-1)
if ! python3 - "$work/profile.plist" "$identity" << 'EOF'; then
import hashlib, plistlib, sys
profile = plistlib.load(open(sys.argv[1], "rb"))
hashes = [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])]
sys.exit(0 if sys.argv[2].upper() in hashes else 1)
EOF
  echo "::error::the provisioning profile was made with another certificate (make it again with this one)"
  exit 1
fi

# 4. 다시 서명
rm -rf "$app/_CodeSignature"
cp "$profile" "$app/embedded.mobileprovision"
while IFS= read -r -d '' code; do
  codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$code" > /dev/null 2>&1 || {
    echo "::error::could not sign $(basename "$code")"
    exit 1
  }
done < <(find "$app" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -print0)
if ! codesign --force --sign "$identity" --keychain "$keychain" --entitlements "$entitlements" --timestamp=none \
  "$app" > /dev/null 2> "$work/codesign.log"; then
  # 오류 문장에 인증서 이름이 들어갈 수 있어 가린다
  sed -E 's/(Apple Distribution|iPhone Distribution): [^"]*/\1: …/g' "$work/codesign.log"
  exit 1
fi
codesign --verify --strict "$app"
signed="$work/$(basename "$ipa" .ipa)-appstore.ipa"
(cd "$work/ipa" && zip -qry "$signed" Payload)
echo "signed $bundle_id $version ($build) for App Store distribution"

# 5. 올리기: altool은 ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8을 찾는다
mkdir -p "$key_dir"
printf '%s\n' "$ASC_KEY_P8" > "$key_dir/AuthKey_$ASC_KEY_ID.p8"
chmod 600 "$key_dir/AuthKey_$ASC_KEY_ID.p8"
if ! apple_id=$(python3 "$scripts/asc.py" app-id "$bundle_id"); then
  echo "$apple_id"
  exit 1
fi
# 실패한 실행을 다시 돌리면 같은 빌드 번호가 된다. 이미 올라가 있으면 다시 올리지 않고 처리 확인만 한다
if ! existing=$(python3 "$scripts/asc.py" build-state "$bundle_id" "$build"); then
  echo "$existing"
  exit 1
fi
if [ -n "$existing" ]; then
  echo "::notice::build $build is already in App Store Connect ($existing); not uploading again"
  result="빌드 번호 \`$build\`는 이미 올라가 있어 다시 올리지 않았다 ($existing)"
else
  echo "uploading to App Store Connect…"
  status=0
  xcrun altool --upload-app -f "$signed" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
    --apple-id "$apple_id" --output-format json > "$work/upload.json" 2> "$work/upload.err" || status=$?
  # Xcode 26의 altool은 실패해도 0을 돌려줄 때가 있어 결과 JSON을 본다
  if python3 "$scripts/asc.py" upload-result "$work/upload.json"; then
    echo "uploaded (altool exit $status)"
  else
    echo "::error::upload failed (altool exit $status)"
    cat "$work/upload.json" "$work/upload.err" | sed -E 's/(Apple Distribution|iPhone Distribution): [^"]*/\1: …/g' | head -60
    exit 1
  fi
  result="올린 빌드: \`$version\` (빌드 번호 \`$build\`)"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "bundle=$bundle_id"
    echo "build=$build"
  } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### TestFlight"
    echo "- $result"
    echo "- App Store Connect에서 처리되면 TestFlight 앱에 나타난다 (다음 작업이 처리 완료를 확인)"
  } >> "$GITHUB_STEP_SUMMARY"
fi
