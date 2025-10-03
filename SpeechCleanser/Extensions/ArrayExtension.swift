//
//  ArrayExtension.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, !isEmpty, sequence.count <= count else { return false }
        
        if sequence.count == 1 {
            return contains(sequence[0])
        }
        
        let limit = count - sequence.count
        if limit < 0 { return false }
        
        for start in 0...limit {
            var isMatch = true
            for offset in 0..<sequence.count {
                if self[start + offset] != sequence[offset] {
                    isMatch = false
                    break
                }
            }
            
            if isMatch {
                return true
            }
        }
        
        return false
    }
}
