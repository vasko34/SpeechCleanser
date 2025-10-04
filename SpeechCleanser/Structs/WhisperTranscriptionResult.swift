//
//  WhisperTranscriptionResult.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 4.10.25.
//

import Foundation

struct WhisperTranscriptionResult {
    let transcript: String
    let windowStartDate: Date
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    
    var segmentDuration: TimeInterval {
        max(endOffset - startOffset, 0)
    }
}
