#!/bin/bash
# XcodeGen을 정해 둔 버전으로 내려받는다 (CI 러너에는 없다). 내려받은 파일은 SHA-256으로 확인한다.
#   scripts/install-xcodegen.sh [설치할 폴더]   (기본: $RUNNER_TEMP 또는 /tmp)
# GitHub Actions에서는 PATH에 넣고, 아니면 PATH에 넣을 폴더를 알려 준다.
set -euo pipefail

version=2.46.0
sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

dest=${1:-${RUNNER_TEMP:-/tmp}}
zip="$dest/xcodegen-$version.zip"
curl -fsSL -o "$zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
echo "$sha256  $zip" | shasum -a 256 -c -
rm -rf "$dest/xcodegen"
unzip -q "$zip" -d "$dest"

bin="$dest/xcodegen/bin"
"$bin/xcodegen" --version
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bin" >> "$GITHUB_PATH"
else
  echo "export PATH=\"$bin:\$PATH\""
fi
