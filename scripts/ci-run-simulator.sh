#!/bin/bash
# CI: 시뮬레이터에서 앱을 띄워 시험한다 (.github/workflows/ios.yml의 simulator 잡)
#   scripts/ci-run-simulator.sh <시뮬레이터 UDID> <.app 경로> <결과 폴더>
# 1. 파이썬 수신기(scripts/facelink_receiver.py)를 띄운다. 시뮬레이터는 호스트와 네트워크를 같이 쓴다
# 2. 앱을 -autotest-send로 띄워 시험 송신(합성 얼굴)을 보내게 한다
# 3. 수신기가 형식, Ack, Calibrate를 확인하고, 앱 로그에서 빌드 번호와 Ack·보정 처리를 확인한다
set -euo pipefail

udid=$1
app=$2
out=$3
mkdir -p "$out"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
port=39539

time xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"

python3 scripts/facelink_receiver.py --host 127.0.0.1 --port "$port" --name CI-Receiver \
  --duration 10 --timeout 120 --calibrate-after 3 --expect-calibrated-position --min-fps 20 \
  --quiet --summary "$out/receiver.json" > "$out/receiver.log" 2>&1 &
receiver_pid=$!

# 앱의 표준 출력(로그)을 app.log로 받는다
xcrun simctl launch --console-pty "$udid" "$bundle_id" -autotest-send "127.0.0.1:$port" > "$out/app.log" 2>&1 &
launch_pid=$!

receiver_status=0
wait "$receiver_pid" || receiver_status=$?
xcrun simctl io "$udid" screenshot "$out/screen.png" > /dev/null 2>&1 || true
xcrun simctl terminate "$udid" "$bundle_id" || true
kill "$launch_pid" 2> /dev/null || true

echo "--- receiver"
cat "$out/receiver.log"
echo "--- app"
cat "$out/app.log"
echo "---"

failed=0
check() {
  if grep -q "$1" "$out/app.log"; then
    echo "ok: $2"
  else
    echo "::error::$2 (no '$1' in app log)"
    failed=1
  fi
}
check "build: #${GITHUB_RUN_NUMBER:-0} " "the app is this run's build"
check "sender: ready" "the app's UDP connection became ready"
check "sender: ack from CI-Receiver" "the app received Ack"
check "sender: calibrate requested by receiver" "the app received Calibrate"
check "sender: calibrated" "the app calibrated"
if [ "$receiver_status" != 0 ]; then
  echo "::error::the receiver found problems (exit $receiver_status), see receiver.log"
  failed=1
fi
exit "$failed"
