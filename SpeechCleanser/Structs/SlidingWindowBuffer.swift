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
    private var startIndex: Int = 0
    private var processedSampleCount: Int = 0
    
    init(windowDuration: TimeInterval, hopDuration: TimeInterval, sampleRate: Int) {
        let window = max(Int(windowDuration * Double(sampleRate)), 1)
        let hop = max(Int(hopDuration * Double(sampleRate)), 1)
        windowSamples = window
        hopSamples = hop
    }
    
    mutating func append(_ samples: [Float]) -> [AudioWindowSegment] {
        guard !samples.isEmpty else { return [] }
        
        buffer.append(contentsOf: samples)
        var windows: [AudioWindowSegment] = []
        
        while buffer.count - startIndex >= windowSamples {
            let upperBound = startIndex + windowSamples
            let window = Array(buffer[startIndex..<upperBound])
            let globalStartIndex = processedSampleCount + startIndex
            windows.append(AudioWindowSegment(samples: window, startSampleIndex: globalStartIndex))
            startIndex = min(startIndex + hopSamples, buffer.count)
        }
        
        if startIndex > 0 && startIndex >= buffer.count / 2 {
            buffer.removeFirst(startIndex)
            processedSampleCount += startIndex
            startIndex = 0
            processedSampleCount = 0
        }
        
        return windows
    }
    
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        startIndex = 0
    }
}
