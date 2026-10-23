#!/bin/bash
# CI: 시뮬레이터에서 앱을 띄워 시험한다 (.github/workflows/ios.yml의 simulator 잡)
#   scripts/ci-run-simulator.sh <시뮬레이터 UDID> <.app 경로> <결과 폴더>
# 1. 파이썬 수신기(scripts/facelink_receiver.py)를 띄운다. 시뮬레이터는 호스트와 네트워크를 같이 쓴다
# 2. 받는 쪽 아이패드인 척 Bonjour(_facelink._udp)로 알린다 (dns-sd)
# 3. 앱을 -autotest-send <QR 주소>로 띄워 시험 송신(합성 얼굴)을 보내게 하고, -autotest-browse로 Bonjour 찾기를 켠다
# 4. 수신기가 형식, 토큰, Ack, Calibrate를 확인하고, 앱 로그에서 빌드 번호, Bonjour 찾기, Ack·보정 처리를 확인한다
set -euo pipefail

udid=$1
app=$2
out=$3
mkdir -p "$out"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
port=39539
token=citoken

time xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"

python3 scripts/facelink_receiver.py --host 127.0.0.1 --port "$port" --name CI-Receiver \
  --duration 10 --timeout 120 --calibrate-after 3 --expect-calibrated-position --min-fps 20 --expect-token "$token" \
  --quiet --summary "$out/receiver.json" > "$out/receiver.log" 2>&1 &
receiver_pid=$!

dns-sd -R CI-iPad _facelink._udp local "$port" v=1 name=CI-iPad > "$out/dns-sd.log" 2>&1 &
dns_sd_pid=$!

# 앱의 표준 출력(로그)을 app.log로 받는다
xcrun simctl launch --console-pty "$udid" "$bundle_id" -autotest-browse \
  -autotest-send "facelink://127.0.0.1:$port?v=1&name=CI-Receiver&token=$token" > "$out/app.log" 2>&1 &
launch_pid=$!

# 스크린숏은 보내는 중에 (수신기가 끝나면 포트가 닫혀 앱에 오류가 보인다). 보정까지 끝나고 상태가 한 번 고쳐진 뒤
for _ in $(seq 1 120); do
  grep -q "sender: calibrated" "$out/app.log" && break
  sleep 1
done
sleep 2
xcrun simctl io "$udid" screenshot "$out/screen.png" > /dev/null 2>&1 || true

receiver_status=0
wait "$receiver_pid" || receiver_status=$?
xcrun simctl terminate "$udid" "$bundle_id" || true
kill "$launch_pid" "$dns_sd_pid" 2> /dev/null || true

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
check "target: 127.0.0.1:$port (CI-Receiver) with token" "the app read the QR address"
check "browse: found CI-iPad (service CI-iPad, v1)" "the app found the receiver by Bonjour"
check "sender: ready" "the app's UDP connection became ready"
check "sender: ack from CI-Receiver" "the app received Ack"
check "sender: calibrate requested by receiver" "the app received Calibrate"
check "sender: calibrated" "the app calibrated"
if [ "$receiver_status" != 0 ]; then
  echo "::error::the receiver found problems (exit $receiver_status), see receiver.log"
  failed=1
fi
exit "$failed"
