"""facelink_receiver.py 시험. python3 -m unittest discover -s scripts -v"""

import os
import socket
import struct
import tempfile
import unittest
import wave

import facelink_receiver as fr

IDENTITY = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)


def body_messages(names=("Spine", "LeftUpperArm", "LeftIndexProximal"), root=True):
    """v1.1 몸: Root → 뼈 (위치 0)"""
    messages = [fr.encode_message(fr.ROOT_POS, "root", *IDENTITY)] if root else []
    return messages + [fr.encode_message(fr.BONE_POS, name, *IDENTITY) for name in names]


def frame_messages(sequence, tracked=True, values=None, head=IDENTITY, eyes=True, body=None):
    """docs/face-link.md 3.1 순서: Frame → Bone(머리, 눈) → 몸(v1.1) → Val ×52 → Apply"""
    values = values or {}
    messages = [fr.encode_message(fr.FRAME, sequence, 1.5, 1 if tracked else 0)]
    if tracked:
        messages.append(fr.encode_message(fr.BONE_POS, "Head", *map(float, head)))
        if eyes:
            for name in ("LeftEye", "RightEye"):
                messages.append(fr.encode_message(fr.BONE_POS, name, *IDENTITY))
    messages += body or []
    if tracked:
        for name in fr.BLEND_SHAPES:
            messages.append(fr.encode_message(fr.BLEND_VAL, name, float(values.get(name, 0.0))))
    messages.append(fr.encode_message(fr.BLEND_APPLY))
    return messages


def audio_packet(sequence, frames=480, channels=1, rate=48000, value=1000, kind=1, sample_time=None, extra=b""):
    """3.8 소리 패킷: 정수는 빅 엔디언, 표본은 s16 리틀 엔디언"""
    if sample_time is None:
        sample_time = (sequence - 1) * frames
    header = fr.AUDIO_MAGIC + bytes([1, kind, channels, 0]) + struct.pack(">IQIHH", sequence, sample_time, rate, frames, 0)
    return header + struct.pack(f"<{frames * channels}h", *([value] * frames * channels)) + extra


def pack(messages, max_size=fr.MAX_DATAGRAM):
    """번들 하나가 max_size를 넘지 않게 나눈다"""
    bundles, current, size = [], [], 16
    for message in messages:
        if current and size + 4 + len(message) > max_size:
            bundles.append(fr.encode_bundle(current))
            current, size = [], 16
        current.append(message)
        size += 4 + len(message)
    if current:
        bundles.append(fr.encode_bundle(current))
    return bundles


def hello(session="S1", token="", features=None):
    if features is None:
        return fr.encode_message(fr.HELLO, "1", "내 iPhone", "0.1.12", session, token)
    return fr.encode_message(fr.HELLO, "1", "내 iPhone", "0.1.12", session, token, features)


def feed(checker, datagrams, now=0.0):
    for datagram in datagrams:
        checker.datagram(datagram, now)


class OSCTests(unittest.TestCase):
    def test_round_trip(self):
        message = fr.encode_message("/a", 1, 2.5, "한글", "")
        self.assertEqual(fr.parse_message(message), ("/a", "ifss", [1, 2.5, "한글", ""]))
        self.assertEqual(len(message) % 4, 0)

    def test_appendix_b_frame_bytes(self):
        # Swift 쪽 OSCTests.frameMessageBytes와 같은 바이트
        data = fr.encode_message(fr.FRAME, 1234, 532.016, 1)
        expected = b"/FaceLink/Frame\0" + b",ifi\0\0\0\0" + bytes([0, 0, 0x04, 0xD2]) + struct.pack(">f", 532.016) \
            + bytes([0, 0, 0, 1])
        self.assertEqual(data, expected)
        self.assertEqual(fr.encode_message(fr.BLEND_APPLY), b"/VMC/Ext/Blend/Apply\0\0\0\0,\0\0\0")

    def test_bundle(self):
        bundle = fr.encode_bundle([fr.encode_message("/a"), fr.encode_message("/b", 1)])
        is_bundle, time_tag, messages = fr.parse_packet(bundle)
        self.assertTrue(is_bundle)
        self.assertEqual(time_tag, 1)
        self.assertEqual([m[0] for m in messages], ["/a", "/b"])
        nested = fr.encode_bundle([bundle])
        self.assertEqual(len(fr.parse_packet(nested)[2]), 2)

    def test_broken_packets(self):
        message = fr.encode_message(fr.FRAME, 1, 2.0, 1)
        for broken in (message[:-2], b"abc\0", b"/x\0\0,d\0\0" + bytes(8), b"#bundlx\0", fr.encode_bundle([message])[:-4]):
            with self.assertRaises(fr.OSCError):
                fr.parse_packet(broken)


class CheckerTests(unittest.TestCase):
    def test_valid_frames(self):
        checker = fr.Checker(expect_token="tok")
        datagrams = pack(frame_messages(1, values={"JawOpen": 0.4}))
        self.assertGreaterEqual(len(datagrams), 2)
        self.assertTrue(all(len(d) <= fr.MAX_DATAGRAM for d in datagrams))
        feed(checker, [hello(token="tok")] + datagrams + pack(frame_messages(2, tracked=False)))
        self.assertEqual(checker.errors, [])
        self.assertEqual((checker.frames, checker.tracked_frames, checker.last_sequence), (2, 1, 2))
        self.assertEqual(checker.device_name, "내 iPhone")
        self.assertIn("얼굴 놓침", checker.status_line(0))

    def assertError(self, datagrams, fragment, **checker_args):
        checker = fr.Checker(**checker_args)
        feed(checker, datagrams)
        self.assertTrue(any(fragment in error for error in checker.errors), checker.errors)

    def test_oversize_datagram(self):
        self.assertError([fr.encode_bundle(frame_messages(1))], "bytes (> 1400)")

    def test_missing_apply(self):
        first = frame_messages(1)[:-1]
        self.assertError(pack(first) + pack(frame_messages(2)), "frame 1 ended without Apply")

    def test_sequence_must_increase_within_session(self):
        self.assertError([hello()] + pack(frame_messages(5)) + pack(frame_messages(5)), "sequence 5 after 5")
        # 세션이 바뀌면 처음부터
        checker = fr.Checker()
        feed(checker, [hello("A")] + pack(frame_messages(5)) + [hello("B")] + pack(frame_messages(1)))
        self.assertEqual(checker.errors, [])

    def test_blend_shape_names_and_values(self):
        messages = frame_messages(1)
        missing = [m for m in messages if b"TongueOut" not in m]
        self.assertError(pack(missing), "has 51 blend shapes")
        wrong = messages[:-1] + [fr.encode_message(fr.BLEND_VAL, "eyeBlink_L", 0.5), messages[-1]]
        self.assertError(pack(wrong), "unknown blend shape 'eyeBlink_L'")
        self.assertError(pack(frame_messages(1, values={"JawOpen": 1.5})), "JawOpen = 1.5")

    def test_bone_rules(self):
        self.assertError(pack(frame_messages(1, head=(0, 0, 0, 0.5, 0, 0, 0.5))), "quaternion length")
        messages = frame_messages(1)
        late_bone = [messages[0]] + messages[4:-1] + messages[1:2] + [messages[-1]]
        self.assertError(pack(late_bone), "Bone/Pos Head after Blend/Val")
        no_head = [m for m in messages if b"Head" not in m]
        self.assertError(pack(no_head), "has no Head bone")

    def test_frame_messages_must_be_in_bundle_with_immediate_time_tag(self):
        self.assertError(frame_messages(1)[:1], "outside a bundle")
        self.assertError([fr.encode_bundle(frame_messages(1)[:1], time_tag=5)], "time tag is 5")

    def test_hello_rules(self):
        self.assertError([hello(token="x")], "token 'x'", expect_token="y")
        self.assertError([fr.encode_message(fr.HELLO, "2", "d", "v", "s", "")], "protocol version '2'")
        self.assertError([fr.encode_message(fr.HELLO, "1", "d")], "expected ,sssss")

    def test_unknown_addresses_are_ignored(self):
        checker = fr.Checker()
        feed(checker, [fr.encode_message("/VMC/Ext/OK", 1)])
        self.assertEqual(checker.errors, [])
        self.assertEqual(checker.ignored["/VMC/Ext/OK"], 1)

    def test_hello_features(self):
        checker = fr.Checker()
        feed(checker, [hello()])
        self.assertEqual(checker.features, ["face"])  # v1 Hello는 얼굴만
        feed(checker, [hello(features="face,body,hands,audio")])
        self.assertEqual(checker.features, ["face", "body", "hands", "audio"])
        self.assertEqual(checker.errors, [])
        self.assertError([hello(features="face,smell")], "['smell'] are unknown")

    def test_body_bones(self):
        checker = fr.Checker()
        feed(checker, [hello(features="face,body,hands")] + pack(frame_messages(1, body=body_messages()))
             + pack(frame_messages(2, tracked=False, body=body_messages(root=False))) + pack(frame_messages(3)))
        self.assertEqual(checker.errors, [])
        self.assertEqual(checker.body_frames, 2)
        self.assertEqual(checker.body_bones_seen, {"Spine", "LeftUpperArm", "LeftIndexProximal"})
        self.assertTrue(checker.root_seen)
        self.assertEqual(checker.summary()["body_bones_seen"], ["Spine", "LeftUpperArm", "LeftIndexProximal"])
        self.assertIn("몸 2 fps 뼈 2 손가락 1", checker.status_line(0))
        self.assertEqual(len(fr.BODY_BONES), 55)

    def test_body_rules(self):
        self.assertError(pack(frame_messages(1, body=body_messages(["LeftWing"]))), "unknown bone 'LeftWing'")
        moved = [fr.encode_message(fr.BONE_POS, "Spine", 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)]
        self.assertError(pack(frame_messages(1, body=moved)), "bone Spine position is not 0")
        messages = frame_messages(1)
        late_root = messages[:-1] + body_messages([])[:1] + messages[-1:]
        self.assertError(pack(late_root), "Root/Pos after Blend/Val")
        self.assertError(pack(frame_messages(1, body=body_messages(["Head"], root=False))), "bone Head twice")

    def test_audio_packets(self):
        checker = fr.Checker()
        # 3을 잃고(4가 먼저 옴), 3은 늦게 온다
        feed(checker, [audio_packet(1), audio_packet(2), audio_packet(4), audio_packet(3)])
        self.assertEqual(checker.errors, [])
        self.assertEqual((checker.audio_packets, checker.audio_lost, checker.audio_late), (4, 1, 1))
        self.assertEqual((checker.audio_rate, checker.audio_channels, checker.audio_peak), (48000, 1, 1000))
        self.assertEqual(checker.audio_time_jumps, 0)
        self.assertIn("소리 48000 Hz", checker.status_line(0))
        # 순번은 넘치면 0부터
        wrapping = fr.Checker()
        feed(wrapping, [audio_packet(2 ** 32 - 1, sample_time=0), audio_packet(0, sample_time=480)])
        self.assertEqual((wrapping.audio_lost, wrapping.audio_late, wrapping.audio_time_jumps), (0, 0, 0))

    def test_audio_rules(self):
        self.assertError([audio_packet(1, extra=b"\0\0")], "bytes for 480 frames")
        self.assertError([audio_packet(1, kind=2)], "format 2")
        self.assertError([audio_packet(1, rate=4000)], "sample rate 4000")
        self.assertError([audio_packet(1, channels=3)], "3 channels")
        self.assertError([fr.AUDIO_MAGIC + bytes(10)], "(< 28)")
        self.assertError([audio_packet(1), audio_packet(2, rate=44100)], "format changed")

    def test_save_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "out.wav")
            checker = fr.Checker(save_audio=path)
            feed(checker, [audio_packet(1, value=100), audio_packet(3, value=300)])
            checker.close()
            with wave.open(path, "rb") as file:
                self.assertEqual((file.getnchannels(), file.getsampwidth(), file.getframerate()), (1, 2, 48000))
                self.assertEqual(file.getnframes(), 3 * 480)  # 잃은 2는 무음
                samples = struct.unpack(f"<{3 * 480}h", file.readframes(3 * 480))
        self.assertEqual((samples[0], samples[480], samples[960]), (100, 0, 300))

    def test_feature_failures(self):
        checker = fr.Checker()
        feed(checker, [hello(features="face,body,hands,audio")] + pack(frame_messages(1, body=body_messages()))
             + [audio_packet(1, value=5000)])
        good = {"average_body_fps": 30, "audio_packets_per_second": 100}
        self.assertEqual(fr.feature_failures(checker, good, ["face", "body", "hands", "audio"]), [])
        slow = {"average_body_fps": 2, "audio_packets_per_second": 10}
        failures = fr.feature_failures(checker, slow, ["body", "audio"])
        self.assertTrue(any("body frames average 2" in failure for failure in failures), failures)
        self.assertTrue(any("audio 10 packets/s" in failure for failure in failures), failures)
        face_only = fr.Checker()
        feed(face_only, [hello()] + pack(frame_messages(1)))
        failures = fr.feature_failures(face_only, good, ["face", "hands", "audio"])
        self.assertTrue(any("lack ['hands', 'audio']" in failure for failure in failures), failures)
        self.assertTrue(any("no finger bones" in failure for failure in failures), failures)
        self.assertTrue(any("nearly silent" in failure for failure in failures), failures)

    def test_euler(self):
        yaw, pitch, roll = fr.unity_euler_degrees(0.0, 0.25881905, 0.0, 0.96592583)  # Y축 30도
        self.assertAlmostEqual(yaw, 30, places=4)
        self.assertAlmostEqual(pitch, 0, places=4)
        self.assertAlmostEqual(roll, 0, places=4)


class ReceiverTests(unittest.TestCase):
    """루프백으로 보내는 쪽 흉내와 주고받는다: Ack와 Calibrate가 프레임이 온 주소로 가는지"""

    def setUp(self):
        self.receiver_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.receiver_socket.bind(("127.0.0.1", 0))
        self.receiver_socket.settimeout(0.01)
        self.sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sender.bind(("127.0.0.1", 0))
        self.sender.settimeout(1.0)
        self.address = self.receiver_socket.getsockname()

    def tearDown(self):
        self.receiver_socket.close()
        self.sender.close()

    def send(self, datagrams):
        for datagram in datagrams:
            self.sender.sendto(datagram, self.address)

    def receive(self):
        data, _ = self.sender.recvfrom(65536)
        return fr.parse_packet(data)[2][0]

    def test_ack_and_calibrate(self):
        checker = fr.Checker()
        receiver = fr.Receiver(self.receiver_socket, "PC", checker, calibrate_after=0.2, log=lambda _: None)
        datagrams = [hello()] + pack(frame_messages(1, head=(0.0, 0.0, 0.35) + IDENTITY[3:]))
        self.send(datagrams)
        for _ in datagrams:
            receiver.step(10.0)
        self.assertEqual(checker.frames, 1)

        # 첫 프레임을 받은 그 자리에서 Ack
        self.assertEqual(self.receive(), (fr.ACK, "ifs", [1, 1.0, "PC"]))
        receiver.step(10.3)
        self.assertEqual(self.receive()[0], fr.CALIBRATE)
        self.assertTrue(receiver.calibrate_sent)

        # 보정 뒤 머리 위치가 0인 프레임
        datagrams = pack(frame_messages(2))
        self.send(datagrams)
        for _ in datagrams:
            receiver.step(10.9)
        self.assertTrue(checker.calibrated_position_seen)
        # 다음 Ack는 1초 뒤. 그동안 받은 프레임 2개
        receiver.step(11.0)
        self.assertEqual(self.receive(), (fr.ACK, "ifs", [2, 2.0, "PC"]))
        self.assertEqual(checker.errors, [])


if __name__ == "__main__":
    unittest.main()
