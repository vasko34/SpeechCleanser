//
//  WhisperConfiguration.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

struct WhisperConfiguration {
    let windowDuration: TimeInterval
    let hopDuration: TimeInterval
    let enableVAD: Bool
    
    init(windowDuration: TimeInterval, hopDuration: TimeInterval, enableVAD: Bool) {
        self.windowDuration = windowDuration
        self.hopDuration = hopDuration
        self.enableVAD = enableVAD
    }
}
