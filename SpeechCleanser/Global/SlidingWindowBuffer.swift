//
//  SlidingWindowBuffer.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

struct SlidingWindowBuffer {
    private let windowSamples: Int
    private let hopSamples: Int
    private var buffer: [Float] = []
    
    init(windowDuration: TimeInterval, hopDuration: TimeInterval, sampleRate: Int) {
        let window = max(Int(windowDuration * Double(sampleRate)), 1)
        let hop = max(Int(hopDuration * Double(sampleRate)), 1)
        windowSamples = window
        hopSamples = hop
    }
    
    mutating func append(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        var windows: [[Float]] = []
        
        while buffer.count >= windowSamples {
            let window = Array(buffer[0..<windowSamples])
            windows.append(window)
            let removeCount = min(hopSamples, buffer.count)
            buffer.removeFirst(removeCount)
        }
        
        return windows
    }
    
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
