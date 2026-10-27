import AVFoundation
import CoreMedia

public enum MicrophoneConverterError: Error, CustomStringConvertible {
    /// PCM이 아니거나 바꿀 수 없는 형식
    case unsupported(String)
    /// CMSampleBuffer에서 표본을 꺼내지 못함
    case copyFailed(OSStatus)
    case convertFailed(String)

    public var description: String {
        switch self {
        case .unsupported(let format): "unsupported format \(format)"
        case .copyFailed(let status): "copy failed (\(status))"
        case .convertFailed(let message): "convert failed (\(message))"
        }
    }
}

/// 마이크 표본(ARKit·AVAudioEngine이 주는 아무 PCM 형식) → 48 kHz 모노 s16 (docs/face-link.md 4.7).
/// 표본률을 바꾸는 변환기는 앞뒤 표본을 이어 쓰므로 하나를 계속 쓴다. 입력 형식이 바뀌면(이어폰을 꽂는 등) 새로 만든다.
/// 한 스레드에서만 쓴다
public final class MicrophoneConverter {
    public let outputFormat: AVAudioFormat
    /// 지금 변환기의 입력 형식 (처음에는 nil). 바뀌었는지 보고 로그를 남기는 데 쓴다
    public private(set) var inputFormat: AVAudioFormat?
    /// 변환에 실패한 수
    public private(set) var failures = 0
    private var converter: AVAudioConverter?

    public init(sampleRate: UInt32 = FaceLinkProtocol.audioSampleRate) {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
    }

    /// ARKit(`session(_:didOutputAudioSampleBuffer:)`)이 주는 것
    public func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Int16] {
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else {
                throw MicrophoneConverterError.unsupported("not audio")
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0 else { return [] }
            guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw MicrophoneConverterError.unsupported(format.summary)
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else { throw MicrophoneConverterError.copyFailed(status) }
            return try convertBuffer(buffer)
        } catch {
            failures += 1
            throw error
        }
    }

    /// AVAudioEngine 입력 탭이 주는 것
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        do {
            return try convertBuffer(buffer)
        } catch {
            failures += 1
            throw error
        }
    }

    private func convertBuffer(_ input: AVAudioPCMBuffer) throws -> [Int16] {
        guard input.frameLength > 0 else { return [] }
        let converter = try makeConverter(for: input.format)
        // 표본률을 바꾸면 변환기가 쥐고 있던 표본이 같이 나올 수 있어 넉넉히
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw MicrophoneConverterError.convertFailed("no output buffer")
        }
        // 입력 블록은 convert 안에서 바로 불린다. 이번 표본을 한 번만 주고, 다음부터는 "아직 없음"(변환기는 이어서 쓴다)
        nonisolated(unsafe) let pending = input
        nonisolated(unsafe) var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return pending
        }
        if status == .error {
            throw MicrophoneConverterError.convertFailed(error?.localizedDescription ?? "unknown")
        }
        guard output.frameLength > 0, let data = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// 형식이 같으면 지금 것을, 바뀌었으면 새로 만든다
    private func makeConverter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, format == inputFormat {
            return converter
        }
        guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM, format.sampleRate > 0,
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw MicrophoneConverterError.unsupported(format.summary)
        }
        // 스테레오(외부 마이크)는 섞어서 모노로 (끄면 첫 채널만 쓴다)
        converter.downmix = format.channelCount > 1
        self.converter = converter
        inputFormat = format
        return converter
    }
}

extension AVAudioFormat {
    /// 로그용: "44100 Hz, 1 ch, s16 interleaved"
    public var summary: String {
        let sample = switch commonFormat {
        case .pcmFormatInt16: "s16"
        case .pcmFormatInt32: "s32"
        case .pcmFormatFloat32: "float32"
        case .pcmFormatFloat64: "float64"
        default: "\(streamDescription.pointee.mBitsPerChannel)-bit"
        }
        return "\(Int(sampleRate)) Hz, \(channelCount) ch, \(sample)\(isInterleaved ? " interleaved" : "")"
    }
}
