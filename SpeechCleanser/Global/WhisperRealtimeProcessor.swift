//
//  WhisperRealtimeProcessor.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import whispercpp

class WhisperRealtimeProcessor {
    struct Configuration {
        let windowDuration: TimeInterval
        let hopDuration: TimeInterval
        let enableVAD: Bool
    }
    
    private let inferenceQueue = DispatchQueue(label: "WhisperRealtimeProcessor.inference", qos: .userInitiated)
    private let context: OpaquePointer
    private let baseSampleRate: Int32 = 16_000
    private let maxTokens: Int32 = 64
    private let configuration: Configuration
    private let modelURL: URL
    private(set) var isOperational: Bool = false
    
    init?(modelURL: URL, configuration: Configuration) {
        self.configuration = configuration
        self.modelURL = modelURL
        
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
    }
    
    deinit {
        whisper_free(context)
        print("[WhisperRealtimeProcessor] deinit: Released whisper context for model \(modelURL.lastPathComponent)")
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
            params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 1))
            params.max_tokens = self.maxTokens
            params.audio_ctx = Int32(self.configuration.windowDuration * Double(self.baseSampleRate))
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
            let requestedSamples = samples.count
            if requestedSamples == 0 {
                completionQueue.async {
                    completion("")
                }
                print("[WhisperRealtimeProcessor][ERROR] transcribe: Sample buffer unexpectedly empty prior to inference")
                return
            }
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
            print("[WhisperRealtimeProcessor] transcribe: Samples=\(requestedSamples) segments=\(segmentCount) duration=\(durationString)s result=\(normalized)")
            
            completionQueue.async {
                completion(normalized)
            }
        }
    }
}
