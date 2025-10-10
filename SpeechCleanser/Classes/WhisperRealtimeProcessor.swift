//
//  WhisperRealtimeProcessor.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Accelerate

class WhisperRealtimeProcessor {
    private struct SpeechGateDecision {
        let isSpeech: Bool
        let rms: Float
        let threshold: Float
        let usedSilero: Bool
    }
    
    private var configuration: WhisperConfiguration?
    private var context: OpaquePointer?
    private var state: OpaquePointer?
    private var vadContext: OpaquePointer?
    private var languageBytes: [CChar] = []
    private var contextTokens: [whisper_token] = []
    private var loggedMissingVAD = false
    
    var isPrepared: Bool { context != nil }
    
    deinit {
        reset()
    }
    
    private func detectSpeech(samples: [Float]) -> SpeechGateDecision {
        var energy: Float = 0
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            vDSP_measqv(baseAddress, 1, &energy, vDSP_Length(samples.count))
        }
        
        if energy < 0 {
            energy = 0
        }
        
        let rms = sqrtf(energy)
        
        if let vadContext = vadContext {
            let detected = samples.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return false }
                return whisper_vad_detect_speech(vadContext, baseAddress, Int32(samples.count))
            }
            return SpeechGateDecision(isSpeech: detected, rms: rms, threshold: 0, usedSilero: true)
        }
        
        let threshold: Float
        if let configuration = configuration, configuration.chunkDuration > 1.0 {
            threshold = 0.02
        } else {
            threshold = 0.015
        }
        
        return SpeechGateDecision(isSpeech: rms > threshold, rms: rms, threshold: threshold, usedSilero: false)
    }
    
    @discardableResult
    private func recreateDecodingState() -> Bool {
        guard let context = context else {
            print("[WhisperRealtimeProcessor][ERROR] recreateDecodingState: Missing context")
            return false
        }
        
        if let existingState = state {
            whisper_free_state(existingState)
            state = nil
        }
        
        let newState = whisper_init_state(context)
        guard let newState else {
            print("[WhisperRealtimeProcessor][ERROR] recreateDecodingState: whisper_init_state returned nil")
            return false
        }
        
        state = newState
        return true
    }
    
    func prepare(configuration: WhisperConfiguration) -> Bool {
        if let current = self.configuration, current.modelSize == configuration.modelSize, context != nil, state != nil {
            self.configuration = configuration
            return true
        }
        
        reset()
        guard let modelPath = configuration.modelURL()?.path else {
            print("[WhisperRealtimeProcessor][ERROR] prepare: Unable to locate model for size \(configuration.modelSize)")
            return false
        }
        
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        
        modelPath.withCString { pointer in
            context = whisper_init_from_file_with_params(pointer, contextParams)
        }
        
        guard let context = context else {
            print("[WhisperRealtimeProcessor][ERROR] prepare: Failed to initialize whisper context")
            return false
        }
        
        state = whisper_init_state(context)
        guard state != nil else {
            print("[WhisperRealtimeProcessor][ERROR] prepare: Failed to initialize whisper state")
            reset()
            return false
        }
        
        if let vadPath = configuration.vadURL()?.path {
            var vadParams = whisper_vad_default_context_params()
            vadParams.n_threads = configuration.threads
            vadParams.use_gpu = true
            
            vadPath.withCString { pointer in
                vadContext = whisper_vad_init_from_file_with_params(pointer, vadParams)
            }
            
            if vadContext == nil {
                print("[WhisperRealtimeProcessor][ERROR] prepare: Unable to load Silero VAD model from \(vadPath)")
            }
        } else if !loggedMissingVAD {
            loggedMissingVAD = true
            print("[WhisperRealtimeProcessor][ERROR] prepare: Silero VAD resource missing; falling back to RMS VAD")
        }
        
        languageBytes = Array(configuration.language.utf8CString)
        contextTokens.removeAll(keepingCapacity: true)
        self.configuration = configuration
        
        print("[WhisperRealtimeProcessor] prepare: Loaded model \(configuration.modelSize) threads=\(configuration.threads)")
        return true
    }
    
    func process(samples: [Float], chunkStartTime: TimeInterval, allowSilenceDecoding: Bool) -> Output? {
        guard !samples.isEmpty else { return nil }
        guard let configuration = configuration, let context = context, let state = state else {
            print("[WhisperRealtimeProcessor][ERROR] process: Processor not prepared")
            return nil
        }
        
        let gateDecision = detectSpeech(samples: samples)
        let speechDetected = gateDecision.isSpeech
        if !speechDetected && !allowSilenceDecoding {
            return Output(results: [], speechDetected: false, didDecode: false, rmsLevel: gateDecision.rms, rmsThreshold: gateDecision.threshold, usedSileroVAD: gateDecision.usedSilero)
        }
        
        var collectedResults: [WhisperTranscriptionResult] = []
        var newTokens: [whisper_token] = []
        var succeeded = false
        var decodeAttempted = false
        
        let runDecode: (UnsafePointer<CChar>?) -> Void = { [weak self] suppressRegexPointer in
            guard let self else { return }
            
            self.languageBytes.withUnsafeBufferPointer { languagePointer in
                guard let languageBase = languagePointer.baseAddress else { return }
                self.contextTokens.withUnsafeBufferPointer { promptPointer in
                    samples.withUnsafeBufferPointer { bufferPointer in
                        guard let baseAddress = bufferPointer.baseAddress else { return }
                        
                        for temperature in configuration.temperatureFallback {
                            var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
                            params.print_realtime = false
                            params.print_progress = false
                            params.print_timestamps = false
                            params.print_special = false
                            params.translate = configuration.translate
                            params.language = languageBase
                            params.detect_language = false
                            params.no_context = false
                            params.single_segment = false
                            params.greedy.best_of = Int32(configuration.bestOf)
                            params.beam_search.beam_size = Int32(configuration.beamSize)
                            params.temperature = temperature
                            params.temperature_inc = 0
                            params.entropy_thold = 2.4
                            params.logprob_thold = -1.0
                            params.no_speech_thold = 0.3
                            params.thold_pt = 0.5
                            params.thold_ptsum = 0.5
                            params.prompt_tokens = promptPointer.baseAddress
                            params.prompt_n_tokens = Int32(promptPointer.count)
                            params.suppress_blank = true
                            params.suppress_nst = false
                            params.suppress_regex = suppressRegexPointer
                            params.n_threads = configuration.threads
                            params.n_max_text_ctx = Int32(configuration.contextTokenCount)
                            
                            let status = whisper_full_with_state(context, state, params, baseAddress, Int32(samples.count))
                            decodeAttempted = true
                            if status == 0 {
                                succeeded = true
                                break
                            }
                            
                            print("[WhisperRealtimeProcessor][ERROR] process: whisper_full_with_state returned status \(status) for temperature \(temperature)")
                        }
                    }
                }
            }
        }
        
        var numeralSuppressionBytes: [CChar] = []
        if configuration.suppressNumerals {
            numeralSuppressionBytes = Array("[0-9]+".utf8CString)
        }
        
        if configuration.suppressNumerals {
            numeralSuppressionBytes.withUnsafeBufferPointer { pointer in
                runDecode(pointer.baseAddress)
            }
        } else {
            runDecode(nil)
        }
        
        guard succeeded else {
            if decodeAttempted {
                if !recreateDecodingState() {
                    print("[WhisperRealtimeProcessor][ERROR] process: Failed to recreate decoding state after decode failure")
                    reset()
                }
            }
            return Output(results: [], speechDetected: speechDetected, didDecode: true, rmsLevel: gateDecision.rms, rmsThreshold: gateDecision.threshold, usedSileroVAD: gateDecision.usedSilero)
        }
        
        let segmentCount = whisper_full_n_segments_from_state(state)
        collectedResults.reserveCapacity(Int(segmentCount))
        
        for index in 0..<segmentCount {
            guard let textPointer = whisper_full_get_segment_text_from_state(state, index) else { continue }
            
            let rawText = String(cString: textPointer)
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let startTicks = whisper_full_get_segment_t0_from_state(state, index)
            let endTicks = whisper_full_get_segment_t1_from_state(state, index)
            let start = chunkStartTime + (Double(startTicks) / 100.0)
            let end = chunkStartTime + (Double(endTicks) / 100.0)
            let tokenCount = whisper_full_n_tokens_from_state(state, index)
            var probabilityAccumulator: Float = 0
            
            for tokenIndex in 0..<tokenCount {
                probabilityAccumulator += whisper_full_get_token_p_from_state(state, index, tokenIndex)
                let token = whisper_full_get_token_id_from_state(state, index, tokenIndex)
                newTokens.append(token)
            }
            
            let averageProbability = tokenCount > 0 ? probabilityAccumulator / Float(tokenCount) : 0
            let result = WhisperTranscriptionResult(text: trimmed, startTime: start, endTime: end, averageProbability: averageProbability, isFinal: true)
            collectedResults.append(result)
        }
        
        if !newTokens.isEmpty {
            if newTokens.count > configuration.contextTokenCount {
                contextTokens = Array(newTokens.suffix(configuration.contextTokenCount))
            } else {
                contextTokens.append(contentsOf: newTokens)
                if contextTokens.count > configuration.contextTokenCount {
                    contextTokens = Array(contextTokens.suffix(configuration.contextTokenCount))
                }
            }
        }
        
        if decodeAttempted {
            if !recreateDecodingState() {
                print("[WhisperRealtimeProcessor][ERROR] process: Failed to recreate decoding state after decode success")
                reset()
            }
        }
        
        return Output(results: collectedResults, speechDetected: speechDetected, didDecode: true, rmsLevel: gateDecision.rms, rmsThreshold: gateDecision.threshold, usedSileroVAD: gateDecision.usedSilero)
    }
    
    func reset() {
        if let state = state {
            whisper_free_state(state)
        }
        if let context = context {
            whisper_free(context)
        }
        if let vadContext = vadContext {
            whisper_vad_free(vadContext)
        }
        
        state = nil
        context = nil
        vadContext = nil
        configuration = nil
        languageBytes.removeAll(keepingCapacity: false)
        contextTokens.removeAll(keepingCapacity: false)
    }
}
