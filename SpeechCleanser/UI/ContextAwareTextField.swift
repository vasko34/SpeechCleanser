//
//  ContextAwareTextField.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 30.09.25.
//

import UIKit

class ContextAwareTextField: UITextField {
    private let contextID = UUID().uuidString
    private var lastResponderLog: Bool = false
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            lastResponderLog = true
            print("[ContextAwareTextField] becomeFirstResponder: Activated with contextID=\(contextID)")
        }
        return result
    }
    
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, lastResponderLog {
            lastResponderLog = false
            print("[ContextAwareTextField] resignFirstResponder: Resigned with contextID=\(contextID)")
        }
        return result
    }
}
