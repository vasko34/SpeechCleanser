//
//  WhisperRealtimeProcessor.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

class WhisperRealtimeProcessor {
    private let inferenceQueue = DispatchQueue(label: "WhisperRealtimeProcessor.inference", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "WhisperRealtimeProcessor.state")
    private let context: OpaquePointer
    private let state: OpaquePointer
    private let baseSampleRate: Int32 = 16_000
    private let maxTokens: Int32 = 48
    private let configuration: WhisperConfiguration
    private let modelURL: URL
    private let normalizer = AudioEnergyNormalizer()
    private let forcedLanguageID: Int32
    
    private var isBusyFlag: Bool = false
    private(set) var isOperational: Bool = false
    
    var isBusy: Bool {
        stateQueue.sync { isBusyFlag }
    }
    
    init?(modelURL: URL, configuration: WhisperConfiguration) {
        self.configuration = configuration
        self.modelURL = modelURL
        
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            print("[WhisperRealtimeProcessor][ERROR] init: Model file missing at path \(path)")
            return nil
        }
        
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
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
        
        forcedLanguageID = "bg".withCString { pointer in
            Int32(whisper_lang_id(pointer))
        }
        
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
    
    private func calculateAmplitudeStats(for samples: [Float]) -> (rms: Float, peak: Float) {
        var rmsAccumulator: Float = 0
        var peak: Float = 0
        
        for sample in samples {
            let absolute = abs(sample)
            peak = max(peak, absolute)
            rmsAccumulator += absolute * absolute
        }
        
        let count = Float(max(samples.count, 1))
        let rms = sqrt(rmsAccumulator / count)
        
        return (rms, peak)
    }
    
    @discardableResult
    func transcribe(samples: [Float], startDate: Date, completionQueue: DispatchQueue, completion: @escaping (WhisperTranscriptionResult) -> Void) -> Bool {
        guard isOperational else {
            print("[WhisperRealtimeProcessor][ERROR] transcribe: Processor not operational for model \(modelURL.lastPathComponent)")
            return false
        }
        guard !samples.isEmpty else {
            print("[WhisperRealtimeProcessor] transcribe: Received empty sample buffer")
            return false
        }
        
        let audioDuration = Double(samples.count) / Double(baseSampleRate)
        var accepted = false
        stateQueue.sync {
            if !isBusyFlag {
                isBusyFlag = true
                accepted = true
            }
        }
        
        guard accepted else {
            print("[WhisperRealtimeProcessor] transcribe: Busy with existing inference, skipping new window")
            return false
        }
        
        inferenceQueue.async { [weak self] in
            guard let self = self else { return }
            
            defer {
                self.stateQueue.sync {
                    self.isBusyFlag = false
                }
            }
            
            let durationMillisecondsDouble = self.configuration.windowDuration * 1000.0
            let clampedDuration = max(1.0, min(Double(Int32.max), durationMillisecondsDouble))
            let durationMilliseconds = Int32(clampedDuration)
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            
            params.print_realtime = false
            params.print_progress = false
            params.translate = false
            params.single_segment = true
            params.no_context = true
            params.no_timestamps = false
            params.detect_language = false
            params.n_max_text_ctx = 0
            params.temperature = 0.2
            params.temperature_inc = 0
            params.n_threads = Int32(max(1, ProcessInfo.processInfo.processorCount - 1))
            params.max_tokens = self.maxTokens
            params.duration_ms = durationMilliseconds
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
            
            let requestedSamples = samples.count
            if requestedSamples > Int(Int32.max) {
                print("[WhisperRealtimeProcessor][ERROR] transcribe: Sample buffer exceeds Int32 capacity with \(requestedSamples) samples")
                let empty = WhisperTranscriptionResult(transcript: "", windowStartDate: startDate, startOffset: 0, endOffset: 0, audioDuration: audioDuration, sampleCount: samples.count)
                
                completionQueue.async {
                    completion(empty)
                }
                
                return
            }
                      
            let amplitude = self.calculateAmplitudeStats(for: samples)
            var inferenceSamples = samples
            var amplitudeForInference = amplitude
            print("[WhisperRealtimeProcessor] transcribe: BufferStats samples=\(requestedSamples) rms=\(String(format: "%.5f", Double(amplitude.rms))) peak=\(String(format: "%.5f", Double(amplitude.peak)))")
            
            if amplitude.peak < 0.00005 && amplitude.rms < 0.00002 {
                print("[WhisperRealtimeProcessor] transcribe: Skipping inference due to low energy window")
                let empty = WhisperTranscriptionResult(transcript: "", windowStartDate: startDate, startOffset: 0, endOffset: 0, audioDuration: audioDuration, sampleCount: samples.count)
                completionQueue.async {
                    completion(empty)
                }
                return
            }
            
            if let normalization = self.normalizer.normalize(samples: samples, amplitude: amplitude) {
                inferenceSamples = normalization.samples
                amplitudeForInference = (normalization.afterRMS, normalization.afterPeak)
                print(String(format: "[WhisperRealtimeProcessor] transcribe: Applied gain %.2fx rms=%.5f->%.5f peak=%.5f->%.5f", Double(normalization.appliedGain), Double(normalization.beforeRMS), Double(normalization.afterRMS), Double(normalization.beforePeak), Double(normalization.afterPeak)))
            }
            
            print("[WhisperRealtimeProcessor] transcribe: NormalizedBuffer rms=\(String(format: "%.5f", Double(amplitudeForInference.rms))) peak=\(String(format: "%.5f", Double(amplitudeForInference.peak)))")
            
            let inferenceStart = CFAbsoluteTimeGetCurrent()
            let resultCode: Int32 = inferenceSamples.withUnsafeBufferPointer { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else {
                    print("[WhisperRealtimeProcessor][ERROR] transcribe: Buffer pointer missing during inference")
                    return Int32(-99)
                }
                
                return "bg".withCString { pointer in
                    var localParams = params
                    localParams.language = pointer
                    whisper_reset_timings(self.context)
                    return whisper_full_with_state(self.context, self.state, localParams, baseAddress, Int32(bufferPointer.count))
                }
            }
            
            if resultCode != 0 {
                print("[WhisperRealtimeProcessor][ERROR] transcribe: whisper_full failed with code \(resultCode) requestedSamples=\(requestedSamples)")
                let empty = WhisperTranscriptionResult(transcript: "", windowStartDate: startDate, startOffset: 0, endOffset: 0, audioDuration: audioDuration, sampleCount: samples.count)
                completionQueue.async {
                    completion(empty)
                }
                return
            }
            
            let segmentCount = whisper_full_n_segments_from_state(self.state)
            if segmentCount <= 0 {
                print("[WhisperRealtimeProcessor] transcribe: No segments detected in current window")
                let empty = WhisperTranscriptionResult(transcript: "", windowStartDate: startDate, startOffset: 0, endOffset: 0, audioDuration: audioDuration, sampleCount: samples.count)
                completionQueue.async {
                    completion(empty)
                }
                return
            }
            
            var earliestStart = TimeInterval.greatestFiniteMagnitude
            var latestEnd: TimeInterval = 0
            var transcript = ""
            transcript.reserveCapacity(256)
            
            for index in 0..<segmentCount {
                if let textPointer = whisper_full_get_segment_text_from_state(self.state, index) {
                    let segment = String(cString: textPointer)
                    transcript.append(segment)
                }
                
                let startTicks = whisper_full_get_segment_t0_from_state(self.state, index)
                if startTicks >= 0 {
                    earliestStart = min(earliestStart, Double(startTicks) / 100.0)
                }
                
                let endTicks = whisper_full_get_segment_t1_from_state(self.state, index)
                if endTicks >= 0 {
                    latestEnd = max(latestEnd, Double(endTicks) / 100.0)
                }
            }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - inferenceStart
            let durationString = String(format: "%.2f", elapsed)
            let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                print("[WhisperRealtimeProcessor] transcribe: Normalized transcript empty after trimming")
            }
            
            if earliestStart == TimeInterval.greatestFiniteMagnitude {
                earliestStart = 0
            }
            
            if latestEnd < earliestStart {
                latestEnd = earliestStart
            }
            
            let trimmedEarliest = max(0, min(earliestStart, audioDuration))
            let trimmedLatest = max(trimmedEarliest, min(latestEnd, audioDuration))
            let detectedLanguageID = whisper_full_lang_id_from_state(self.state)
            if detectedLanguageID != self.forcedLanguageID {
                let expected = whisper_lang_str_full(Int32(self.forcedLanguageID))
                let detected = whisper_lang_str_full(Int32(detectedLanguageID))
                let expectedString = expected.map { String(cString: $0) } ?? "unknown"
                let detectedString = detected.map { String(cString: $0) } ?? "unknown"
                print("[WhisperRealtimeProcessor][ERROR] transcribe: Language mismatch expected=\(expectedString) detected=\(detectedString)")
            }
            
            print("[WhisperRealtimeProcessor] transcribe: Samples=\(requestedSamples) segments=\(segmentCount) duration=\(durationString)s windowOffsets=\(String(format: "%.2f", trimmedEarliest))s-\(String(format: "%.2f", trimmedLatest))s result=\(normalized)")
            
            let result = WhisperTranscriptionResult(transcript: normalized, windowStartDate: startDate, startOffset: trimmedEarliest, endOffset: trimmedLatest, audioDuration: audioDuration, sampleCount: samples.count)
            
            completionQueue.async {
                completion(result)
            }
        }
        
        return true
    }
}
