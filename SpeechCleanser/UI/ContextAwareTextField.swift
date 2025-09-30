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
    private lazy var fallbackContextIdentifier = "SpeechCleanser." + contextID
    private var didLogFallbackContext = false
    
    override var textInputContextIdentifier: String? {
        if let identifier = super.textInputContextIdentifier, !identifier.isEmpty {
            return identifier
        }
        
        if !didLogFallbackContext {
            didLogFallbackContext = true
            print("[ContextAwareTextField] textInputContextIdentifier: Using fallback identifier \(fallbackContextIdentifier)")
        }
        
        return fallbackContextIdentifier
    }
    
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
