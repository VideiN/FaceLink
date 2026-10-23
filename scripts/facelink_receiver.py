#!/usr/bin/env python3
"""FaceLink v1 받는 쪽 흉내 (docs/face-link.md). 파이썬 표준 라이브러리만 쓴다.

두 가지로 쓴다.

- CI: 앱의 시험 송신을 받아 형식을 확인한다. 문제가 있으면 0이 아닌 값으로 끝난다
    python3 scripts/facelink_receiver.py --duration 10 --calibrate-after 3 \\
        --expect-token citoken --expect-calibrated-position --summary out.json
- PC(Windows 등)에서 아이폰이 보내는 값 보기: 1초마다 상태를 한 줄씩 찍는다
    python scripts/facelink_receiver.py

보내는 쪽에 1초마다 /FaceLink/Ack를, --calibrate-after가 있으면 /FaceLink/Calibrate를 한 번 보낸다 (3.5).
"""

import argparse
import collections
import json
import math
import socket
import struct
import sys
import time
import urllib.parse

DEFAULT_PORT = 39539
MAX_DATAGRAM = 1400
PROTOCOL_VERSION = "1"

HELLO = "/FaceLink/Hello"
FRAME = "/FaceLink/Frame"
ACK = "/FaceLink/Ack"
CALIBRATE = "/FaceLink/Calibrate"
BLEND_VAL = "/VMC/Ext/Blend/Val"
BLEND_APPLY = "/VMC/Ext/Blend/Apply"
BONE_POS = "/VMC/Ext/Bone/Pos"
FRAME_ADDRESSES = {FRAME, BLEND_VAL, BLEND_APPLY, BONE_POS}
BONES = {"Head", "LeftEye", "RightEye"}

# 부록 A: 보내는 이름 (ARKit 52개, Perfect Sync 표기)
BLEND_SHAPES = [
    "EyeBlinkLeft", "EyeLookDownLeft", "EyeLookInLeft", "EyeLookOutLeft", "EyeLookUpLeft", "EyeSquintLeft", "EyeWideLeft",
    "EyeBlinkRight", "EyeLookDownRight", "EyeLookInRight", "EyeLookOutRight", "EyeLookUpRight", "EyeSquintRight",
    "EyeWideRight",
    "JawForward", "JawLeft", "JawRight", "JawOpen",
    "MouthClose", "MouthFunnel", "MouthPucker", "MouthLeft", "MouthRight", "MouthSmileLeft", "MouthSmileRight",
    "MouthFrownLeft", "MouthFrownRight", "MouthDimpleLeft", "MouthDimpleRight", "MouthStretchLeft", "MouthStretchRight",
    "MouthRollLower", "MouthRollUpper", "MouthShrugLower", "MouthShrugUpper", "MouthPressLeft", "MouthPressRight",
    "MouthLowerDownLeft", "MouthLowerDownRight", "MouthUpperUpLeft", "MouthUpperUpRight",
    "BrowDownLeft", "BrowDownRight", "BrowInnerUp", "BrowOuterUpLeft", "BrowOuterUpRight",
    "CheekPuff", "CheekSquintLeft", "CheekSquintRight", "NoseSneerLeft", "NoseSneerRight",
    "TongueOut",
]
BLEND_SHAPE_SET = set(BLEND_SHAPES)


# --- OSC 1.0 ---------------------------------------------------------------

class OSCError(Exception):
    pass


def _read_string(data, offset, start):
    """널로 끝나고 (start 기준) 4바이트 정렬된 문자열"""
    end = data.find(b"\0", offset)
    if end < 0:
        raise OSCError("string without null")
    try:
        text = data[offset:end].decode("utf-8")
    except UnicodeDecodeError as error:
        raise OSCError(f"string is not UTF-8: {error}") from None
    next_offset = start + ((end - start + 4) & ~3)
    if next_offset > len(data):
        raise OSCError("string padding is truncated")
    return text, next_offset


def parse_message(data):
    """(주소, 타입 태그, 인자 목록)"""
    address, offset = _read_string(data, 0, 0)
    if not address.startswith("/"):
        raise OSCError(f"bad address {address!r}")
    if offset == len(data):
        return address, "", []
    tags, offset = _read_string(data, offset, 0)
    if not tags.startswith(","):
        raise OSCError(f"bad type tags {tags!r}")
    args = []
    for tag in tags[1:]:
        if tag in "if":
            if offset + 4 > len(data):
                raise OSCError(f"{address}: truncated argument")
            args.append(struct.unpack(">i" if tag == "i" else ">f", data[offset:offset + 4])[0])
            offset += 4
        elif tag == "s":
            text, offset = _read_string(data, offset, 0)
            args.append(text)
        else:
            raise OSCError(f"{address}: unsupported type tag {tag!r}")
    return address, tags[1:], args


def parse_packet(data):
    """(번들인지, 바깥 번들의 time tag 또는 None, [(주소, 타입 태그, 인자)])"""
    if data.startswith(b"#"):
        if not data.startswith(b"#bundle\0") or len(data) < 16:
            raise OSCError("bad bundle header")
        (time_tag,) = struct.unpack(">Q", data[8:16])
        messages = []
        offset = 16
        while offset < len(data):
            if offset + 4 > len(data):
                raise OSCError("truncated bundle element size")
            (size,) = struct.unpack(">i", data[offset:offset + 4])
            offset += 4
            if size <= 0 or offset + size > len(data):
                raise OSCError(f"bad bundle element size {size}")
            messages.extend(parse_packet(data[offset:offset + size])[2])
            offset += size
        return True, time_tag, messages
    return False, None, [parse_message(data)]


def _osc_string(text):
    raw = text.encode("utf-8") + b"\0"
    return raw + b"\0" * (-len(raw) % 4)


def encode_message(address, *args):
    """int → i, float → f, str → s"""
    tags = ","
    payload = b""
    for arg in args:
        if isinstance(arg, bool) or not isinstance(arg, (int, float, str)):
            raise TypeError(f"unsupported OSC argument {arg!r}")
        if isinstance(arg, int):
            tags += "i"
            payload += struct.pack(">i", arg)
        elif isinstance(arg, float):
            tags += "f"
            payload += struct.pack(">f", arg)
        else:
            tags += "s"
            payload += _osc_string(arg)
    return _osc_string(address) + _osc_string(tags) + payload


def encode_bundle(elements, time_tag=1):
    data = b"#bundle\0" + struct.pack(">Q", time_tag)
    for element in elements:
        data += struct.pack(">i", len(element)) + element
    return data


# --- 형식 확인 ---------------------------------------------------------------

def unity_euler_degrees(qx, qy, qz, qw):
    """화면에 보일 대략의 (yaw, pitch, roll). Unity 좌표(+Y 위) 쿼터니언"""
    yaw = math.atan2(2 * (qw * qy + qx * qz), 1 - 2 * (qx * qx + qy * qy))
    pitch = math.asin(max(-1.0, min(1.0, 2 * (qw * qx - qy * qz))))
    roll = math.atan2(2 * (qw * qz + qx * qy), 1 - 2 * (qx * qx + qz * qz))
    return tuple(math.degrees(value) for value in (yaw, pitch, roll))


class Checker:
    """데이터그램을 받아 FaceLink v1 형식을 확인하고 통계를 모은다"""

    MAX_ERRORS_KEPT = 50

    def __init__(self, expect_token=None):
        self.expect_token = expect_token
        self.errors = []
        self.error_count = 0
        self.datagrams = 0
        self.max_datagram = 0
        self.hellos = 0
        self.device_name = None
        self.app_version = None
        self.session = None
        self.sessions = 0
        self.token = None
        self.last_sequence = None
        self.frames = 0
        self.tracked_frames = 0
        self.frame_times = collections.deque()
        self.current = None
        self.last_frame = None
        self.ignored = collections.Counter()
        self.calibrate_sent_at = None
        self.calibrated_position_seen = False

    def error(self, message):
        self.error_count += 1
        if len(self.errors) < self.MAX_ERRORS_KEPT:
            self.errors.append(message)

    def fps(self, now):
        while self.frame_times and now - self.frame_times[0] > 1.0:
            self.frame_times.popleft()
        return len(self.frame_times)

    def datagram(self, data, now):
        self.datagrams += 1
        self.max_datagram = max(self.max_datagram, len(data))
        if len(data) > MAX_DATAGRAM:
            self.error(f"datagram is {len(data)} bytes (> {MAX_DATAGRAM})")
        try:
            is_bundle, time_tag, messages = parse_packet(data)
        except OSCError as error:
            self.error(f"unreadable packet: {error}")
            return
        for address, tags, args in messages:
            if address == HELLO:
                self.hello(tags, args)
            elif address in FRAME_ADDRESSES:
                if not is_bundle:
                    self.error(f"{address} outside a bundle")
                elif time_tag != 1:
                    self.error(f"bundle time tag is {time_tag}, not 1 (immediately)")
                self.frame_message(address, tags, args, now)
            else:
                # 모르는 주소는 무시한다 (VMC 규칙)
                self.ignored[address] += 1

    def hello(self, tags, args):
        self.hellos += 1
        if tags != "sssss":
            self.error(f"Hello type tags ,{tags} (expected ,sssss)")
            return
        version, device, app_version, session, token = args
        if version != PROTOCOL_VERSION:
            self.error(f"Hello protocol version {version!r}")
        if not session:
            self.error("Hello without a session ID")
        if self.expect_token is not None and token != self.expect_token:
            self.error(f"Hello token {token!r} (expected {self.expect_token!r})")
        if session != self.session:
            # 새 세션은 순번을 처음부터 받는다
            self.session = session
            self.sessions += 1
            self.last_sequence = None
        self.device_name, self.app_version, self.token = device, app_version, token

    def frame_message(self, address, tags, args, now):
        if address == FRAME:
            if tags != "ifi":
                self.error(f"Frame type tags ,{tags} (expected ,ifi)")
                return
            sequence, sent_time, tracked = args
            if self.current is not None:
                self.error(f"frame {self.current['sequence']} ended without Apply")
            if self.last_sequence is not None and sequence <= self.last_sequence:
                self.error(f"sequence {sequence} after {self.last_sequence}")
            if tracked not in (0, 1):
                self.error(f"tracking state {tracked}")
            self.current = {
                "sequence": sequence, "time": sent_time, "tracked": tracked == 1,
                "bones": {}, "values": {}, "seen_value": False,
            }
            return

        frame = self.current
        if frame is None:
            self.error(f"{address} before /FaceLink/Frame")
            return

        if address == BONE_POS:
            if tags != "sfffffff":
                self.error(f"Bone/Pos type tags ,{tags} (expected ,sfffffff)")
                return
            name, *numbers = args
            if name not in BONES:
                self.error(f"unknown bone {name!r}")
            if frame["seen_value"]:
                self.error(f"Bone/Pos {name} after Blend/Val")
            if name in frame["bones"]:
                self.error(f"bone {name} twice in frame {frame['sequence']}")
            norm = math.sqrt(sum(value * value for value in numbers[3:]))
            if abs(norm - 1) > 1e-3:
                self.error(f"bone {name} quaternion length {norm:.4f}")
            if name in ("LeftEye", "RightEye") and any(abs(value) > 1e-6 for value in numbers[:3]):
                self.error(f"bone {name} position is not 0")
            frame["bones"][name] = numbers
        elif address == BLEND_VAL:
            if tags != "sf":
                self.error(f"Blend/Val type tags ,{tags} (expected ,sf)")
                return
            name, value = args
            frame["seen_value"] = True
            if name not in BLEND_SHAPE_SET:
                self.error(f"unknown blend shape {name!r}")
            if name in frame["values"]:
                self.error(f"blend shape {name} twice in frame {frame['sequence']}")
            if not 0 <= value <= 1:
                self.error(f"blend shape {name} = {value}")
            frame["values"][name] = value
        elif address == BLEND_APPLY:
            if tags:
                self.error(f"Apply with arguments ,{tags}")
            self.finish_frame(frame, now)

    def finish_frame(self, frame, now):
        self.current = None
        if frame["tracked"]:
            self.tracked_frames += 1
            if len(frame["values"]) != len(BLEND_SHAPES):
                self.error(f"frame {frame['sequence']} has {len(frame['values'])} blend shapes")
            if "Head" not in frame["bones"]:
                self.error(f"frame {frame['sequence']} has no Head bone")
        elif frame["bones"] or frame["values"]:
            # 놓친 프레임에 값이 있어도 틀린 것은 아니다 (빼도 된다)
            pass
        self.frames += 1
        self.last_sequence = frame["sequence"]
        self.frame_times.append(now)
        self.last_frame = frame
        head = frame["bones"].get("Head")
        if self.calibrate_sent_at is not None and now - self.calibrate_sent_at > 0.5 and head:
            if math.sqrt(sum(value * value for value in head[:3])) < 1e-4:
                self.calibrated_position_seen = True

    def status_line(self, now):
        frame = self.last_frame
        parts = [f"{self.fps(now):3d} fps"]
        if self.device_name is not None:
            parts.append(f"{self.device_name} {self.app_version}")
        if frame is None:
            parts.append("프레임 없음")
        elif not frame["tracked"]:
            parts.append("얼굴 놓침")
        else:
            head = frame["bones"].get("Head")
            if head:
                yaw, pitch, roll = unity_euler_degrees(*head[3:])
                parts.append(f"머리 yaw {yaw:+5.1f} pitch {pitch:+5.1f} roll {roll:+5.1f}")
            values = frame["values"]
            parts.append(f"입 {values.get('JawOpen', 0):.2f}")
            parts.append(f"눈 감음 L {values.get('EyeBlinkLeft', 0):.2f} R {values.get('EyeBlinkRight', 0):.2f}")
        parts.append(f"오류 {self.error_count}")
        return " · ".join(parts)

    def summary(self):
        return {
            "datagrams": self.datagrams,
            "max_datagram_bytes": self.max_datagram,
            "hellos": self.hellos,
            "sessions": self.sessions,
            "device_name": self.device_name,
            "app_version": self.app_version,
            "token": self.token,
            "frames": self.frames,
            "tracked_frames": self.tracked_frames,
            "last_sequence": self.last_sequence,
            "calibrated_position_seen": self.calibrated_position_seen,
            "ignored_addresses": dict(self.ignored),
            "error_count": self.error_count,
            "errors": self.errors,
        }


# --- 받기 -----------------------------------------------------------------

class Receiver:
    def __init__(self, sock, name, checker, calibrate_after=None, log=print):
        self.sock = sock
        self.name = name
        self.checker = checker
        self.calibrate_after = calibrate_after
        self.log = log
        self.sender = None
        self.first_frame_at = None
        self.next_ack_at = None
        self.calibrate_at = None
        self.acks_sent = 0
        self.calibrate_sent = False

    def step(self, now):
        """데이터그램을 하나 받거나(소켓 타임아웃까지 기다림) Ack·Calibrate 때가 되었으면 보낸다"""
        try:
            data, address = self.sock.recvfrom(65536)
        except (socket.timeout, BlockingIOError):
            data = None
        except ConnectionResetError:
            # Windows는 앞서 보낸 데이터그램의 ICMP "포트 닫힘"을 여기서 알린다
            data = None
        if data is not None:
            self.sender = address
            self.checker.datagram(data, now)
            if self.first_frame_at is None and self.checker.frames > 0:
                self.first_frame_at = now
                self.next_ack_at = now
                if self.calibrate_after is not None:
                    self.calibrate_at = now + self.calibrate_after
        if self.sender is not None and self.next_ack_at is not None and now >= self.next_ack_at:
            ack = encode_message(ACK, self.checker.last_sequence or 0, float(self.checker.fps(now)), self.name)
            self.send(ack)
            self.acks_sent += 1
            self.next_ack_at += 1.0
        if self.calibrate_at is not None and now >= self.calibrate_at:
            self.send(encode_message(CALIBRATE))
            self.log("sent /FaceLink/Calibrate")
            self.checker.calibrate_sent_at = now
            self.calibrate_sent = True
            self.calibrate_at = None

    def send(self, data):
        try:
            self.sock.sendto(data, self.sender)
        except OSError as error:
            self.log(f"send to {self.sender} failed: {error}")


def local_addresses():
    addresses = set()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))  # 실제로 보내지는 않는다. 바깥으로 나가는 인터페이스의 주소만 알아낸다
            addresses.add(probe.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addresses.add(info[4][0])
    except OSError:
        pass
    return sorted(address for address in addresses if not address.startswith("127."))


def print_connection_help(port, name, token):
    addresses = local_addresses()
    if not addresses:
        print(f"이 PC의 IP 주소를 찾지 못했습니다. 포트 {port}로 기다립니다.")
        return
    for address in addresses:
        # 공백은 +가 아니라 %20으로 (앱의 URLComponents는 +를 공백으로 읽지 않는다)
        query = urllib.parse.urlencode({"v": PROTOCOL_VERSION, "name": name, "token": token},
                                       quote_via=urllib.parse.quote)
        url = f"facelink://{address}:{port}?{query}"
        print(f"아이폰 앱에서 직접 입력: {address}:{port}")
        print(f"QR로 만들 주소: {url}")
    try:
        import qrcode  # 있으면 터미널에 QR을 그린다 (pip install qrcode)
    except ImportError:
        return
    qr = qrcode.QRCode(border=1)
    qr.add_data(url)
    qr.print_ascii(invert=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="FaceLink v1 받는 쪽 흉내: 형식 확인과 값 보기")
    parser.add_argument("--host", default="0.0.0.0", help="받을 주소 (기본: 모든 인터페이스)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--name", default=socket.gethostname(), help="Ack에 넣을 받는 쪽 이름")
    parser.add_argument("--token", default="", help="QR 주소에 넣을 페어링 토큰")
    parser.add_argument("--duration", type=float, help="첫 프레임부터 이만큼(초) 받고 끝낸다. 없으면 Ctrl+C까지")
    parser.add_argument("--timeout", type=float, default=0, help="이만큼(초) 동안 프레임이 하나도 없으면 실패로 끝낸다")
    parser.add_argument("--calibrate-after", type=float, help="첫 프레임부터 이만큼(초) 뒤에 Calibrate를 보낸다")
    parser.add_argument("--expect-token", help="Hello의 토큰이 이것이어야 한다")
    parser.add_argument("--expect-calibrated-position", action="store_true",
                        help="Calibrate 뒤에 머리 위치가 0인 프레임이 와야 한다 (시험 송신은 머리 위치가 늘 같다)")
    parser.add_argument("--min-fps", type=float, default=0, help="받은 프레임의 평균 fps가 이보다 낮으면 실패")
    parser.add_argument("--summary", help="결과를 JSON으로 쓸 파일")
    parser.add_argument("--quiet", action="store_true", help="1초마다 상태를 찍지 않는다")
    args = parser.parse_args(argv)

    if hasattr(sys.stdout, "reconfigure"):
        # 파일로 돌리면 Windows에서도 UTF-8로 (터미널에는 그대로)
        encoding = None if sys.stdout.isatty() else "utf-8"
        sys.stdout.reconfigure(encoding=encoding, errors="replace", line_buffering=True)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    sock.settimeout(0.05)
    print(f"FaceLink 받는 쪽 \"{args.name}\": UDP {args.host}:{args.port}에서 기다립니다 (Ctrl+C로 끝)")
    if not args.quiet:
        print_connection_help(args.port, args.name, args.token)

    checker = Checker(expect_token=args.expect_token)
    receiver = Receiver(sock, args.name, checker, args.calibrate_after)
    start = time.monotonic()
    next_status = start + 1
    timed_out = False
    try:
        while True:
            now = time.monotonic()
            receiver.step(now)
            if not args.quiet and now >= next_status:
                print(checker.status_line(now))
                next_status += 1
            if args.duration is not None and receiver.first_frame_at is not None \
                    and now - receiver.first_frame_at >= args.duration:
                break
            if args.timeout and receiver.first_frame_at is None and now - start >= args.timeout:
                timed_out = True
                break
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()

    summary = checker.summary()
    elapsed = (time.monotonic() - receiver.first_frame_at) if receiver.first_frame_at is not None else 0
    summary["seconds"] = round(elapsed, 2)
    summary["average_fps"] = round(checker.frames / elapsed, 1) if elapsed > 0 else 0
    summary["acks_sent"] = receiver.acks_sent
    summary["calibrate_sent"] = receiver.calibrate_sent

    failures = []
    if timed_out:
        failures.append(f"no frames within {args.timeout} s")
    if checker.error_count:
        failures.append(f"{checker.error_count} format errors")
    if args.duration is not None and not timed_out:
        if checker.hellos < max(1, int(args.duration) - 1):
            failures.append(f"only {checker.hellos} Hello in {args.duration} s")
        if summary["average_fps"] < args.min_fps:
            failures.append(f"average {summary['average_fps']} fps < {args.min_fps}")
    if args.expect_calibrated_position and not timed_out:
        if not receiver.calibrate_sent:
            failures.append("Calibrate was not sent (use --calibrate-after shorter than --duration)")
        elif not checker.calibrated_position_seen:
            failures.append("no frame with head position 0 after Calibrate")
    summary["failures"] = failures

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.summary:
        with open(args.summary, "w", encoding="utf-8") as file:
            json.dump(summary, file, ensure_ascii=False, indent=2)
    if failures:
        print("FAILED: " + "; ".join(failures))
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
