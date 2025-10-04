//
//  Result.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 4.10.25.
//

import Foundation

struct Result {
    let samples: [Float]
    let appliedGain: Float
    let beforeRMS: Float
    let beforePeak: Float
    let afterRMS: Float
    let afterPeak: Float
}
