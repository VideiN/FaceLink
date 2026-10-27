#!/usr/bin/env python3
"""FaceLink v1(v1.1 포함) 받는 쪽 흉내 (docs/face-link.md). 파이썬 표준 라이브러리만 쓴다.

두 가지로 쓴다.

- CI: 앱의 시험 송신을 받아 형식을 확인한다. 문제가 있으면 0이 아닌 값으로 끝난다
    python3 scripts/facelink_receiver.py --duration 10 --calibrate-after 3 \\
        --expect-token citoken --expect-calibrated-position --expect-features face,body,hands,audio --summary out.json
- PC(Windows 등)에서 아이폰이 보내는 값 보기: 1초마다 상태를 한 줄씩 찍는다.
  --save-audio로 아이폰이 보내는 소리(3.8)를 WAV 파일로 남긴다
    python scripts/facelink_receiver.py --save-audio iphone.wav

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
import wave

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
ROOT_POS = "/VMC/Ext/Root/Pos"
FRAME_ADDRESSES = {FRAME, BLEND_VAL, BLEND_APPLY, BONE_POS, ROOT_POS}
FACE_BONES = {"Head", "LeftEye", "RightEye"}
# v1.1 몸 뼈 (3.2): Unity HumanBodyBones 55개, 같은 순서
BODY_BONES = [
    "Hips", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot", "Spine",
    "Chest", "Neck", "Head", "LeftShoulder", "RightShoulder", "LeftUpperArm", "RightUpperArm", "LeftLowerArm",
    "RightLowerArm", "LeftHand", "RightHand", "LeftToes", "RightToes", "LeftEye", "RightEye", "Jaw",
] + [side + finger + joint
     for side in ("Left", "Right")
     for finger in ("Thumb", "Index", "Middle", "Ring", "Little")
     for joint in ("Proximal", "Intermediate", "Distal")] + ["UpperChest"]
BONES = set(BODY_BONES)
FINGER_JOINTS = ("Proximal", "Intermediate", "Distal")
# v1.1 Hello의 여섯째 인자 (3.3). 없으면 얼굴만
FEATURES = ("face", "body", "hands", "audio")

# v1.1 소리 패킷 (3.8)
AUDIO_MAGIC = b"FLAU"
AUDIO_HEADER = 28

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


def recent_count(times, now):
    """지난 1초 안의 수 (오래된 것은 지운다)"""
    while times and now - times[0] > 1.0:
        times.popleft()
    return len(times)


def is_finger(name):
    return name.endswith(FINGER_JOINTS)


class Checker:
    """데이터그램을 받아 FaceLink v1(v1.1) 형식을 확인하고 통계를 모은다.
    save_audio가 있으면 받은 소리를 그 WAV 파일로 쓴다 (잃은 패킷은 무음으로). 다 쓰면 close()"""

    MAX_ERRORS_KEPT = 50

    def __init__(self, expect_token=None, save_audio=None):
        self.expect_token = expect_token
        self.save_audio = save_audio
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
        # v1.1 몸
        self.features = None
        self.body_frames = 0
        self.body_times = collections.deque()
        self.body_bones_seen = set()
        self.last_body = set()
        self.root_seen = False
        # v1.1 소리
        self.audio_packets = 0
        self.audio_times = collections.deque()
        self.audio_lost = 0
        self.audio_late = 0
        self.audio_time_jumps = 0
        self.audio_rate = None
        self.audio_channels = None
        self.audio_next_sequence = None
        self.audio_next_sample_time = None
        self.audio_peak = 0
        self.audio_recent_peak = 0
        self.audio_writer = None

    def error(self, message):
        self.error_count += 1
        if len(self.errors) < self.MAX_ERRORS_KEPT:
            self.errors.append(message)

    def fps(self, now):
        return recent_count(self.frame_times, now)

    def close(self):
        if self.audio_writer is not None:
            self.audio_writer.close()
            self.audio_writer = None

    def datagram(self, data, now):
        self.datagrams += 1
        self.max_datagram = max(self.max_datagram, len(data))
        if len(data) > MAX_DATAGRAM:
            self.error(f"datagram is {len(data)} bytes (> {MAX_DATAGRAM})")
        if data.startswith(AUDIO_MAGIC):
            self.audio_packet(data, now)
            return
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
        if tags not in ("sssss", "ssssss"):
            self.error(f"Hello type tags ,{tags} (expected ,sssss or v1.1 ,ssssss)")
            return
        version, device, app_version, session, token = args[:5]
        # v1.1: 여섯째 인자 = 지금 보내는 것. v1 Hello는 얼굴만
        self.features = [feature for feature in (args[5] if len(args) > 5 else "face").split(",") if feature]
        unknown = [feature for feature in self.features if feature not in FEATURES]
        if unknown:
            self.error(f"Hello features {unknown} are unknown")
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
            # 위치는 머리만 (눈·몸 뼈는 0, 3.2)
            if name != "Head" and any(abs(value) > 1e-6 for value in numbers[:3]):
                self.error(f"bone {name} position is not 0")
            frame["bones"][name] = numbers
        elif address == ROOT_POS:
            if not tags.startswith("sfffffff"):
                self.error(f"Root/Pos type tags ,{tags} (expected ,sfffffff)")
                return
            if frame["seen_value"]:
                self.error("Root/Pos after Blend/Val")
            if "root" in frame:
                self.error(f"Root/Pos twice in frame {frame['sequence']}")
            norm = math.sqrt(sum(value * value for value in args[4:8]))
            if abs(norm - 1) > 1e-3:
                self.error(f"Root/Pos quaternion length {norm:.4f}")
            frame["root"] = args[1:8]
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
        # v1.1 몸: 얼굴 뼈 말고 뼈가 있거나 Root가 있는 프레임
        body = set(frame["bones"]) - FACE_BONES
        if body or "root" in frame:
            self.body_frames += 1
            self.body_times.append(now)
            self.body_bones_seen |= body
            self.root_seen = self.root_seen or "root" in frame
            self.last_body = body
        head = frame["bones"].get("Head")
        if self.calibrate_sent_at is not None and now - self.calibrate_sent_at > 0.5 and head:
            if math.sqrt(sum(value * value for value in head[:3])) < 1e-4:
                self.calibrated_position_seen = True

    def audio_packet(self, data, now):
        """3.8 소리 패킷: 머리 28바이트(정수는 빅 엔디언), 표본은 s16 리틀 엔디언"""
        if len(data) < AUDIO_HEADER:
            self.error(f"audio packet is {len(data)} bytes (< {AUDIO_HEADER})")
            return
        version, kind, channels, reserved = data[4:8]
        sequence, sample_time, rate, frames, reserved2 = struct.unpack(">IQIHH", data[8:AUDIO_HEADER])
        problems = []
        if version != 1:
            problems.append(f"version {version}")
        if kind != 1:
            problems.append(f"format {kind} (expected 1 = PCM s16)")
        if channels not in (1, 2):
            problems.append(f"{channels} channels")
        if reserved or reserved2:
            problems.append("reserved bytes are not 0")
        if not 8000 <= rate <= 96000:
            problems.append(f"sample rate {rate}")
        if not 1 <= frames <= 4096:
            problems.append(f"{frames} frames")
        elif channels in (1, 2) and len(data) != AUDIO_HEADER + frames * channels * 2:
            problems.append(f"{len(data)} bytes for {frames} frames x {channels} ch")
        if problems:
            self.error("audio packet: " + ", ".join(problems))
            return

        self.audio_packets += 1
        self.audio_times.append(now)
        if self.audio_rate is not None and (rate, channels) != (self.audio_rate, self.audio_channels):
            self.error(f"audio format changed from {self.audio_rate} Hz {self.audio_channels} ch to {rate} Hz {channels} ch")
        self.audio_rate, self.audio_channels = rate, channels

        # 순번: 앞으로 건너뛰면 잃은 것, 뒤로 가면 늦게 온 것 (늦은 것은 버린다, 3.8)
        missing = 0
        if self.audio_next_sequence is not None:
            gap = (sequence - self.audio_next_sequence) % 2 ** 32
            if gap >= 2 ** 31:
                self.audio_late += 1
                return
            missing = gap
            self.audio_lost += gap
        if missing == 0 and self.audio_next_sample_time is not None and sample_time != self.audio_next_sample_time:
            self.audio_time_jumps += 1
        self.audio_next_sequence = (sequence + 1) % 2 ** 32
        self.audio_next_sample_time = sample_time + frames

        samples = struct.unpack(f"<{frames * channels}h", data[AUDIO_HEADER:])
        peak = max(abs(sample) for sample in samples)
        self.audio_peak = max(self.audio_peak, peak)
        self.audio_recent_peak = max(self.audio_recent_peak, peak)
        if self.save_audio:
            if self.audio_writer is None:
                self.audio_writer = wave.open(self.save_audio, "wb")
                self.audio_writer.setnchannels(channels)
                self.audio_writer.setsampwidth(2)
                self.audio_writer.setframerate(rate)
            if missing:
                self.audio_writer.writeframes(bytes(missing * frames * channels * 2))
            # WAV도 리틀 엔디언이라 표본 바이트를 그대로
            self.audio_writer.writeframes(data[AUDIO_HEADER:])

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
        if self.body_frames:
            fingers = sum(1 for name in self.last_body if is_finger(name))
            parts.append(f"몸 {recent_count(self.body_times, now)} fps 뼈 {len(self.last_body) - fingers} 손가락 {fingers}")
        if self.audio_packets:
            # 소리 크기는 지난 줄부터의 최댓값 (dBFS)
            level = 20 * math.log10(self.audio_recent_peak / 32768) if self.audio_recent_peak else -math.inf
            self.audio_recent_peak = 0
            parts.append(f"소리 {self.audio_rate} Hz {recent_count(self.audio_times, now)}개/s {level:.0f} dB 잃음 {self.audio_lost}")
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
            "features": self.features,
            "body_frames": self.body_frames,
            "body_bones_seen": [name for name in BODY_BONES if name in self.body_bones_seen],
            "root_seen": self.root_seen,
            "audio_packets": self.audio_packets,
            "audio_rate": self.audio_rate,
            "audio_channels": self.audio_channels,
            "audio_lost": self.audio_lost,
            "audio_late": self.audio_late,
            "audio_time_jumps": self.audio_time_jumps,
            "audio_peak": self.audio_peak,
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


def feature_failures(checker, summary, expected):
    """--expect-features: Hello가 그 기능을 알리고, 실제로 왔는지 (시험 송신: 몸 30Hz, 소리 초당 100개)"""
    failures = []
    missing = [feature for feature in expected if feature not in (checker.features or [])]
    if missing:
        failures.append(f"Hello features {checker.features} lack {missing}")
    if "body" in expected:
        if summary["average_body_fps"] < 10:
            failures.append(f"body frames average {summary['average_body_fps']} fps < 10")
        if not checker.body_bones_seen - {name for name in checker.body_bones_seen if is_finger(name)}:
            failures.append("no body bones other than fingers")
    if "hands" in expected and not any(is_finger(name) for name in checker.body_bones_seen):
        failures.append("no finger bones")
    if "audio" in expected:
        if summary["audio_packets_per_second"] < 80:
            failures.append(f"audio {summary['audio_packets_per_second']} packets/s < 80")
        if checker.audio_peak < 1000:
            failures.append(f"audio peak {checker.audio_peak} is nearly silent")
    return failures


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
    parser.add_argument("--expect-features",
                        help="v1.1: Hello의 기능에 이것들(쉼표로, 예: face,body,hands,audio)이 있고 실제로 와야 한다")
    parser.add_argument("--save-audio", help="v1.1: 받은 소리를 이 WAV 파일로 쓴다")
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

    checker = Checker(expect_token=args.expect_token, save_audio=args.save_audio)
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
        checker.close()

    summary = checker.summary()
    elapsed = (time.monotonic() - receiver.first_frame_at) if receiver.first_frame_at is not None else 0
    summary["seconds"] = round(elapsed, 2)
    summary["average_fps"] = round(checker.frames / elapsed, 1) if elapsed > 0 else 0
    summary["average_body_fps"] = round(checker.body_frames / elapsed, 1) if elapsed > 0 else 0
    summary["audio_packets_per_second"] = round(checker.audio_packets / elapsed, 1) if elapsed > 0 else 0
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
    if args.expect_features and not timed_out:
        failures += feature_failures(checker, summary, [f for f in args.expect_features.split(",") if f])
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
