//
//  WhisperTranscriptionResult.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 4.10.25.
//

import Foundation

struct WhisperTranscriptionResult {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let averageProbability: Float
    let isFinal: Bool
    var duration: TimeInterval { endTime - startTime }
}
