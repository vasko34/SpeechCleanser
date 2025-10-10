//
//  WhisperConfiguration.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

struct WhisperConfiguration {
    let modelSize: ModelSize
    let sampleRate: Double
    let frameDuration: TimeInterval
    let chunkDuration: TimeInterval
    let overlapDuration: TimeInterval
    let language: String
    let translate: Bool
    let threads: Int32
    let beamSize: Int32
    let bestOf: Int32
    let temperatureFallback: [Float]
    let suppressNumerals: Bool
    let contextTokenCount: Int
    
    var chunkFrameCount: Int { Int(chunkDuration * sampleRate) }
    var overlapFrameCount: Int { Int(overlapDuration * sampleRate) }
    var strideFrameCount: Int { max(1, chunkFrameCount - overlapFrameCount) }
    var strideDuration: TimeInterval { chunkDuration - overlapDuration }
    
    static func `default`(for size: ModelSize) -> WhisperConfiguration {
        let processorCount = ProcessInfo.processInfo.processorCount
        let threads = Int32(max(2, processorCount - 1))
        return WhisperConfiguration(
            modelSize: size,
            sampleRate: 16_000,
            frameDuration: 0.02,
            chunkDuration: 1.0,
            overlapDuration: 0.2,
            language: "bg",
            translate: false,
            threads: threads,
            beamSize: 5,
            bestOf: 5,
            temperatureFallback: [0.0, 0.2, 0.4, 0.6],
            suppressNumerals: false,
            contextTokenCount: 12
        )
    }
    
    func modelURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelSize.resourceName, withExtension: "bin", subdirectory: "WhisperResources")
    }
    
    func vadURL(in bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: "ggml-vad-silero-v5", withExtension: "bin", subdirectory: "WhisperResources") {
            return url
        }
        
        return bundle.url(forResource: "silero_vad_v5", withExtension: "bin", subdirectory: "WhisperResources")
    }
}
