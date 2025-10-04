//
//  AudioDownsampler.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import AVFoundation

class AudioDownsampler {
    private let targetChannelCount: AVAudioChannelCount = 1
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    
    let targetSampleRate: Double
    
    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: targetChannelCount, interleaved: false) else {
            fatalError("[AudioDownsampler][ERROR] init: Unable to create target format for sample rate \(targetSampleRate)")
        }
        
        targetFormat = format
    }
    
    func reset() {
        converter = nil
    }
    
    func convert(buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        
        if buffer.format.sampleRate == targetSampleRate,
           buffer.format.channelCount == targetChannelCount,
           let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            let pointer = UnsafeBufferPointer(start: channel, count: frames)
            return Array(pointer)
        }
        
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            if converter == nil {
                print("[AudioDownsampler][ERROR] convert: Failed to create AVAudioConverter from format \(buffer.format)")
                return []
            }
            converter?.downmix = true
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        }
        
        guard let converter else {
            print("[AudioDownsampler][ERROR] convert: Converter unavailable after initialization")
            return []
        }
        
        let estimatedCapacity = AVAudioFrameCount(Double(frameLength) * (targetSampleRate / buffer.format.sampleRate) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedCapacity) else {
            print("[AudioDownsampler][ERROR] convert: Unable to allocate output buffer with capacity \(estimatedCapacity)")
            return []
        }
        
        var conversionError: NSError?
        var hasProvidedBuffer = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedBuffer {
                outStatus.pointee = .endOfStream
                return nil
            }
            
            hasProvidedBuffer = true
            outStatus.pointee = .haveData
            return buffer
        }
        
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        switch status {
        case .haveData:
            break
        case .inputRanDry:
            print("[AudioDownsampler][ERROR] convert: Converter reported inputRanDry status")
            return []
        case .endOfStream:
            if let conversionError {
                print("[AudioDownsampler][ERROR] convert: Conversion ended with error \(conversionError.localizedDescription)")
            } else {
                print("[AudioDownsampler][ERROR] convert: Conversion ended unexpectedly at endOfStream")
            }
            return []
        default:
            print("[AudioDownsampler][ERROR] convert: Converter returned unknown status \(status.rawValue)")
            return []
        }
        
        guard let channelData = outputBuffer.floatChannelData else {
            print("[AudioDownsampler][ERROR] convert: Missing channel data in converted buffer")
            return []
        }
        
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            print("[AudioDownsampler][ERROR] convert: Converted buffer contains zero frames")
            return []
        }
        
        let pointer = UnsafeBufferPointer(start: channelData[0], count: frameCount)
        return Array(pointer)
    }
}
