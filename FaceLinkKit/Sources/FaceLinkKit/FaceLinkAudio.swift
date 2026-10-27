/// 소리 패킷 (v1.1, docs/face-link.md 3.8). OSC가 아니라 "FLAU"로 시작한다 (OSC는 '/'나 '#').
/// 머리 28바이트의 정수는 빅 엔디언(OSC와 같게), 표본만 s16 리틀 엔디언
public enum FaceLinkAudioPacket {
    public static let magic: [UInt8] = Array("FLAU".utf8)
    public static let headerSize = 28
    /// 패킷 버전
    public static let version: UInt8 = 1
    /// 형식 1 = PCM signed 16비트 리틀 엔디언
    public static let pcm16: UInt8 = 1

    /// samples는 채널이 2면 L R을 섞은 것. 표본 수(채널당)는 4096 이하
    public static func encode(
        sequence: UInt32, sampleTime: UInt64, sampleRate: UInt32, channels: UInt8 = 1, samples: [Int16]
    ) -> [UInt8] {
        precondition(channels == 1 || channels == 2)
        let frames = samples.count / Int(channels)
        precondition(frames * Int(channels) == samples.count && frames <= 4096)
        var bytes = magic
        bytes.reserveCapacity(headerSize + samples.count * 2)
        bytes += [version, pcm16, channels, 0]
        bytes.appendBigEndian(sequence)
        bytes.appendBigEndian(sampleTime)
        bytes.appendBigEndian(sampleRate)
        bytes.appendBigEndian(UInt16(frames))
        bytes.appendBigEndian(UInt16(0))
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8(value >> 8))
        }
        return bytes
    }
}

/// 모노 표본을 10ms(48 kHz에서 480표본)씩 끊어 소리 패킷으로 (3.8).
/// 순번은 1부터 1씩(넘치면 0부터), 표본 시각은 그 패킷 첫 표본의 번호(0부터)
public struct AudioPacketizer: Sendable {
    public let sampleRate: UInt32
    public let framesPerPacket: Int
    private var pending: [Int16] = []
    private var nextSequence: UInt32
    private var sampleTime: UInt64 = 0

    public init(
        sampleRate: UInt32 = FaceLinkProtocol.audioSampleRate,
        framesPerPacket: Int = FaceLinkProtocol.audioFramesPerPacket,
        firstSequence: UInt32 = 1
    ) {
        self.sampleRate = sampleRate
        self.framesPerPacket = framesPerPacket
        nextSequence = firstSequence
    }

    /// 표본을 더하고 다 찬 패킷들을 낸다. 모자란 나머지는 다음 표본과 합친다
    public mutating func packets(appending samples: [Int16]) -> [[UInt8]] {
        pending += samples
        var packets: [[UInt8]] = []
        var start = 0
        while pending.count - start >= framesPerPacket {
            packets.append(FaceLinkAudioPacket.encode(
                sequence: nextSequence,
                sampleTime: sampleTime,
                sampleRate: sampleRate,
                samples: Array(pending[start..<start + framesPerPacket])
            ))
            nextSequence &+= 1
            sampleTime += UInt64(framesPerPacket)
            start += framesPerPacket
        }
        pending.removeFirst(start)
        return packets
    }
}
