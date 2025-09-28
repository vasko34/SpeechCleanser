//
//  AudioManager.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import AVFoundation
import Accelerate

final class AudioManager {
    private init() {}
    static let shared = AudioManager()
    
    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private var isRunning = false
    
    var onAudioLevel: ((Float) -> Void)?
    var running: Bool { isRunning }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AVAudioSession configuration failed with error: \(error.localizedDescription)")
        }
        
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            var rms: Float = 0
            if let data = channelData, frameLength > 0 {
                var sum: Float = 0
                vDSP_measqv(data, 1, &sum, vDSP_Length(frameLength))
                rms = sqrtf(sum)
            }
            self.onAudioLevel?(rms)
        }
        
        engine.prepare()
        
        do {
            try engine.start()
        } catch {
            print("AVAudioEngine failed to start engine with error: \(error.localizedDescription)")
        }
        
        isRunning = true
    }
    
    func stop() {
        guard isRunning else { return }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        
        do {
            try session.setActive(false)
        } catch {
            print("AVAudioSession failed to setActive with error: \(error.localizedDescription)")
        }
        
        isRunning = false
    }
}
