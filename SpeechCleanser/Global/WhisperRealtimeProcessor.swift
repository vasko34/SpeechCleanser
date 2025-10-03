//
//  WhisperRealtimeProcessor.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

class WhisperRealtimeProcessor {
    struct Configuration {
        let windowDuration: TimeInterval
        let hopDuration: TimeInterval
        let enableVAD: Bool
    }
    
    private let inferenceQueue = DispatchQueue(label: "WhisperRealtimeProcessor.inference", qos: .userInitiated)
    private let context: OpaquePointer
    private let state: OpaquePointer
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
        
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = false
        contextParams.dtw_aheads_preset = WHISPER_AHEADS_NONE
        
        guard let loadedContext = whisper_init_from_file_with_params(path, contextParams) else {
            print("[WhisperRealtimeProcessor][ERROR] init: whisper_init_from_file failed for \(modelURL.lastPathComponent)")
            return nil
        }
        
        context = loadedContext
        guard let allocatedState = whisper_init_state(loadedContext) else {
            whisper_free(loadedContext)
            print("[WhisperRealtimeProcessor][ERROR] init: whisper_init_state failed for model \(modelURL.lastPathComponent)")
            return nil
        }
        
        state = allocatedState
        isOperational = true
        
        let vadStatus = configuration.enableVAD ? "enabled" : "disabled"
        print("[WhisperRealtimeProcessor] init: whisper.cpp ready with model \(modelURL.lastPathComponent) VAD=\(vadStatus) window=\(configuration.windowDuration)s hop=\(configuration.hopDuration)s")
        
        if let systemInfoPointer = whisper_print_system_info() {
            let systemInfo = String(cString: systemInfoPointer)
            print("[WhisperRealtimeProcessor] init: System info -> \(systemInfo)")
        }
    }
    
    deinit {
        whisper_free_state(state)
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
            
            let lang = strdup("bg")
            defer { free(lang) }
            
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.translate = false
            params.single_segment = true
            params.no_context = true
            params.no_timestamps = true
            params.detect_language = false
            params.language = UnsafePointer<CChar>(lang)
            params.n_max_text_ctx = 0
            params.temperature = 0.2
            params.temperature_inc = 0.2
            params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 1))
            params.max_tokens = self.maxTokens
            params.audio_ctx = Int32(self.configuration.windowDuration * Double(self.baseSampleRate))
            params.duration_ms = Int32(self.configuration.windowDuration * 1000.0)
            params.offset_ms = 0
            params.prompt_tokens = nil
            params.prompt_n_tokens = 0
            params.entropy_thold = 2.4
            params.logprob_thold = -1.0
            params.no_speech_thold = 0.35
            
            if self.configuration.enableVAD {
                params.vad = true
                params.vad_model_path = nil
                var vadParams = whisper_vad_default_params()
                vadParams.threshold = 0.60
                vadParams.min_speech_duration_ms = Int32(max(self.configuration.hopDuration * 1000.0, 80.0))
                vadParams.min_silence_duration_ms = 200
                vadParams.max_speech_duration_s = Float(self.configuration.windowDuration)
                vadParams.speech_pad_ms = 120
                vadParams.samples_overlap = Float(self.configuration.hopDuration)
                params.vad_params = vadParams
                print("[WhisperRealtimeProcessor] transcribe: VAD enabled threshold=\(vadParams.threshold) minSpeechMs=\(vadParams.min_speech_duration_ms) padMs=\(vadParams.speech_pad_ms)")
            } else {
                params.vad = false
                print("[WhisperRealtimeProcessor] transcribe: VAD disabled for current request")
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
                      
            if requestedSamples > Int(Int32.max) {
                completionQueue.async {
                    completion("")
                }
                print("[WhisperRealtimeProcessor][ERROR] transcribe: Sample buffer exceeds Int32 capacity with \(requestedSamples) samples")
                return
            }
                      
            let resultCode: Int32 = samples.withUnsafeBufferPointer { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return Int32(-99) }
                
                whisper_reset_timings(self.context)
                return whisper_full_with_state(self.context, self.state, params, baseAddress, Int32(bufferPointer.count))
            }
            
            if resultCode != 0 {
                print("[WhisperRealtimeProcessor][ERROR] transcribe: whisper_full failed with code \(resultCode)")
                completionQueue.async {
                    completion("")
                }
                return
            }
            
            let segmentCount = whisper_full_n_segments_from_state(self.state)
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
                if let textPointer = whisper_full_get_segment_text_from_state(self.state, index) {
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
