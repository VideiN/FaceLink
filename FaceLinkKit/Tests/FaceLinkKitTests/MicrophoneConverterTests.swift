import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import FaceLinkKit

/// 모노 s16 (interleaved)
private func int16Buffer(sampleRate: Double, samples: [Int16]) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let data = try #require(buffer.int16ChannelData)
    for (index, sample) in samples.enumerated() {
        data[0][index] = sample
    }
    return buffer
}

/// float32 (채널마다 따로, AVAudioEngine의 기본 형식). 모든 채널에 같은 값
private func floatBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, value: (Int) -> Float) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<Int(channels) {
        for index in 0..<frames {
            data[channel][index] = value(index)
        }
    }
    return buffer
}

/// ARKit이 주는 것처럼 CMSampleBuffer로 싼다
private func sampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
    var result: CMSampleBuffer?
    var status = CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &result
    )
    #expect(status == noErr)
    let sampleBuffer = try #require(result)
    status = CMSampleBufferSetDataBufferFromAudioBufferList(
        sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: buffer.audioBufferList
    )
    #expect(status == noErr)
    return sampleBuffer
}

/// 0을 지나는 수 (주파수를 대강 본다)
private func zeroCrossings(_ samples: some Collection<Int16>) -> Int {
    zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
}

/// 이미 48 kHz 모노 s16이면 그대로
@Test func converterPassesThroughOutputFormat() throws {
    let converter = MicrophoneConverter()
    let samples = (0..<480).map { Int16($0 * 10 - 2400) }
    #expect(try converter.convert(int16Buffer(sampleRate: 48000, samples: samples)) == samples)
    #expect(converter.inputFormat?.summary == "48000 Hz, 1 ch, s16 interleaved")
    #expect(converter.failures == 0)
}

@Test func converterConvertsFloatTo16Bit() throws {
    let converter = MicrophoneConverter()
    let output = try converter.convert(floatBuffer(sampleRate: 48000, channels: 1, frames: 480) { _ in 0.5 })
    #expect(output.count == 480)
    #expect(output.allSatisfy { abs(Int($0) - 16384) <= 1 })
}

/// 44.1 kHz 스테레오 → 48 kHz 모노: 표본 수가 48/44.1배, 1 kHz 사인파가 그대로 1 kHz
@Test func converterResamplesAndDownmixes() throws {
    let converter = MicrophoneConverter()
    var output: [Int16] = []
    for chunk in 0..<10 {
        let buffer = try floatBuffer(sampleRate: 44100, channels: 2, frames: 441) { index in
            let time = Float(chunk * 441 + index) / 44100
            return 0.5 * sin(2 * Float.pi * 1000 * time)
        }
        output += try converter.convert(buffer)
    }
    // 변환기가 조금 쥐고 있을 수 있다
    #expect(output.count > 4800 - 480 && output.count <= 4800 + 2)
    let peak = output.map { Int($0).magnitude }.max() ?? 0
    #expect(peak > 8000 && peak <= 32768)
    let middle = output.dropFirst(200)
    let expected = Double(middle.count) * 2 * 1000 / 48000
    #expect(abs(Double(zeroCrossings(middle)) - expected) < expected * 0.1)
    #expect(converter.inputFormat?.summary == "44100 Hz, 2 ch, float32")
}

/// ARKit 경로: CMSampleBuffer(44.1 kHz 모노 s16)에서 꺼내 바꾼다
@Test func converterReadsSampleBuffers() throws {
    let converter = MicrophoneConverter()
    var output: [Int16] = []
    for chunk in 0..<10 {
        let samples = (0..<1024).map { index -> Int16 in
            let time = Float(chunk * 1024 + index) / 44100
            return Int16(8000 * sin(2 * Float.pi * 440 * time))
        }
        output += try converter.convert(sampleBuffer(int16Buffer(sampleRate: 44100, samples: samples)))
    }
    let expected = 10 * 1024 * 48000 / 44100
    #expect(output.count > expected - 480 && output.count <= expected + 2)
    let peak = output.map { Int($0).magnitude }.max() ?? 0
    #expect(peak > 6000 && peak < 10000)
    #expect(converter.inputFormat?.summary == "44100 Hz, 1 ch, s16 interleaved")
}

/// 입력 형식이 바뀌면(이어폰 등) 변환기를 새로 만든다
@Test func converterFollowsFormatChange() throws {
    let converter = MicrophoneConverter()
    #expect(try converter.convert(int16Buffer(sampleRate: 48000, samples: [Int16](repeating: 1000, count: 480))).count == 480)
    let output = try converter.convert(floatBuffer(sampleRate: 24000, channels: 1, frames: 2400) { _ in 0.25 })
    #expect(output.count > 4800 - 480 && output.count <= 4800 + 2)
    #expect(converter.inputFormat?.sampleRate == 24000)
}
