//
//  WhisperRealtimeProcessor.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation
#if canImport(whispercpp)
import whispercpp
#endif

class WhisperRealtimeProcessor {
    struct Configuration {
        let windowDuration: TimeInterval
        let hopDuration: TimeInterval
        let enableVAD: Bool
    }
    
    private let configuration: Configuration
    private let modelURL: URL
    private(set) var isOperational: Bool = false
    
    #if canImport(whispercpp)
    private let context: OpaquePointer
    private let inferenceQueue = DispatchQueue(label: "WhisperRealtimeProcessor.inference", qos: .userInitiated)
    #endif
    
    init?(modelURL: URL, configuration: Configuration) {
        self.configuration = configuration
        self.modelURL = modelURL
        
        #if canImport(whispercpp)
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            print("[WhisperRealtimeProcessor][ERROR] init: Model file missing at path \(path)")
            return nil
        }
        
        guard let loadedContext = whisper_init_from_file(path) else {
            print("[WhisperRealtimeProcessor][ERROR] init: whisper_init_from_file failed for \(modelURL.lastPathComponent)")
            return nil
        }
        
        context = loadedContext
        isOperational = true
        print("[WhisperRealtimeProcessor] init: whisper.cpp ready with model \(modelURL.lastPathComponent)")
        #else
        print("[WhisperRealtimeProcessor][ERROR] init: whisper.cpp module unavailable for model \(modelURL.lastPathComponent)")
        return nil
        #endif
    }
    
    deinit {
        #if canImport(whispercpp)
        whisper_free(context)
        print("[WhisperRealtimeProcessor] deinit: Released whisper context for model \(modelURL.lastPathComponent)")
        #endif
    }
    
    func transcribe(samples: [Float], completionQueue: DispatchQueue, completion: @escaping (String) -> Void) {
        guard isOperational else {
            completionQueue.async {
                completion("")
            }
            print("[WhisperRealtimeProcessor][ERROR] transcribe: Processor not operational for model \(modelURL.lastPathComponent)")
            return
        }
        
        guard !samples.isEmpty else {
            print("[WhisperRealtimeProcessor] transcribe: Received empty sample buffer")
            completionQueue.async {
                completion("")
            }
            return
        }
        
        #if canImport(whispercpp)
        inferenceQueue.async { [weak self] in
            guard let self = self else { return }
            
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.translate = false
            params.single_segment = true
            params.no_context = true
            params.no_timestamps = true
            params.temperature = 0.2
            params.temperature_inc = 0.2
            params.max_tokens = 64
            params.audio_ctx = Int32(self.configuration.windowDuration * 16000.0)
            params.speed_up = false
            params.detect_language = true
            
            if self.configuration.enableVAD {
                params.enable_vad = true
                params.vad_thold = 0.6
                params.vad_min_duration_ms = Int32(max(self.configuration.hopDuration * 1000.0, 100))
                params.vad_max_duration_ms = Int32(self.configuration.windowDuration * 1000.0)
                params.vad_delay_ms = Int32(self.configuration.hopDuration * 1000.0)
            } else {
                params.enable_vad = false
            }
            
            let start = CFAbsoluteTimeGetCurrent()
            let resultCode: Int32 = samples.withUnsafeBufferPointer { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return Int32(-99) }
                whisper_reset_timings(self.context)
                return whisper_full(self.context, params, baseAddress, Int32(bufferPointer.count))
            }
            
            if resultCode != 0 {
                print("[WhisperRealtimeProcessor][ERROR] transcribe: whisper_full failed with code \(resultCode)")
                completionQueue.async {
                    completion("")
                }
                return
            }
            
            let segmentCount = whisper_full_n_segments(self.context)
            if segmentCount <= 0 {
                print("[WhisperRealtimeProcessor] transcribe: No segments detected in current window")
                completionQueue.async {
                    completion("")
                }
                return
            }
            
            var transcript = ""
            transcript.reserveCapacity(256)
            
            for index in 0..<segmentCount {
                if let textPointer = whisper_full_get_segment_text(self.context, index) {
                    let segment = String(cString: textPointer)
                    transcript.append(segment)
                }
            }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let durationString = String(format: "%.2f", elapsed)
            let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                print("[WhisperRealtimeProcessor] transcribe: Normalized transcript empty after trimming")
            }
            print("[WhisperRealtimeProcessor] transcribe: Segments=\(segmentCount) duration=\(durationString)s result=\(normalized)")
            
            completionQueue.async {
                completion(normalized)
            }
        }
        #else
        completionQueue.async {
            completion("")
        }
        #endif
    }
}
