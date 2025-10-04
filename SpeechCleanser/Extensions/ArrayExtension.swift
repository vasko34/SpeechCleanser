//
//  ArrayExtension.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

extension Array where Element == String {
    func firstIndexOfSequence(_ sequence: [String]) -> Int? {
        guard !sequence.isEmpty, !isEmpty, sequence.count <= count else { return nil }
        
        if sequence.count == 1 {
            return firstIndex(of: sequence[0])
        }
        
        let limit = count - sequence.count
        if limit < 0 { return nil }
        
        for start in 0...limit {
            var isMatch = true
            for offset in 0..<sequence.count {
                if self[start + offset] != sequence[offset] {
                    isMatch = false
                    break
                }
            }
            
            if isMatch {
                return start
            }
        }
        
        return nil
    }
    
    func containsSequence(_ sequence: [String]) -> Bool {
        firstIndexOfSequence(sequence) != nil
    }
}
