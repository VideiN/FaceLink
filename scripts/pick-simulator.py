"""CI에서 쓸 아이폰 시뮬레이터의 UDID를 고른다.

    xcrun simctl list devices available --json | python3 scripts/pick-simulator.py

가장 새 iOS 런타임에서 사용자 기기(iPhone Pro Max)와 화면이 비슷한 것을 먼저, 없으면 아무 아이폰이나.
"""

import json
import sys


def runtime_version(runtime):
    # "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → (26, 5)
    return tuple(int(part) for part in runtime.rsplit(".iOS-", 1)[1].split("-"))


def pick(devices):
    runtimes = sorted((r for r in devices if ".iOS-" in r), key=runtime_version, reverse=True)
    for runtime in runtimes:
        iphones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
        if not iphones:
            continue
        pro_max = [d for d in iphones if d["name"].endswith("Pro Max")]
        return sorted(pro_max or iphones, key=lambda d: d["name"])[-1]
    return None


def main():
    device = pick(json.load(sys.stdin)["devices"])
    if device is None:
        sys.exit("no iPhone simulator")
    print(f"{device['name']} ({device['udid']})", file=sys.stderr)
    print(device["udid"])


if __name__ == "__main__":
    main()
