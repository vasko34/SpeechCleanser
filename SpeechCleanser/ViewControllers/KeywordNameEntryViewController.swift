//
//  KeywordNameEntryViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit

class KeywordNameEntryViewController: UIViewController {
    private let textField = UITextField()
    private let descriptionLabel = UILabel()
    
    private var keyboardActivationWorkItem: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var didActivateKeyboard = false
    
    var onSave: ((String) -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .systemBackground
        title = "New Keyword"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        
        descriptionLabel.text = "Record variations after saving the keyword."
        descriptionLabel.font = .systemFont(ofSize: 15)
        descriptionLabel.numberOfLines = 0
        
        textField.placeholder = "Enter keyword name"
        textField.borderStyle = .roundedRect
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(descriptionLabel)
        view.addSubview(textField)
        
        NSLayoutConstraint.activate([
            descriptionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            textField.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textField.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.deactivateKeyboard(reason: "willResignActive")
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleKeyboardActivation(reason: "didBecomeActive")
        }
        
        print("[KeywordNameEntryViewController] viewDidLoad: Ready for input")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleKeyboardActivation(reason: "viewDidAppear")
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        deactivateKeyboard(reason: "viewWillDisappear")
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        keyboardActivationWorkItem?.cancel()
    }
    
    private func scheduleKeyboardActivation(reason: String) {
        guard view.window != nil else { return }
        if didActivateKeyboard, textField.isFirstResponder { return }
        
        keyboardActivationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.view.window != nil else { return }
            guard !self.textField.isFirstResponder else { return }
            
            self.didActivateKeyboard = true
            if self.textField.becomeFirstResponder() {
                print("[KeywordNameEntryViewController] scheduleKeyboardActivation: Activated text field via \(reason)")
            }
        }
        
        keyboardActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
    
    private func deactivateKeyboard(reason: String) {
        keyboardActivationWorkItem?.cancel()
        keyboardActivationWorkItem = nil
        if textField.isFirstResponder {
            textField.resignFirstResponder()
            print("[KeywordNameEntryViewController] deactivateKeyboard: Resigned text field via \(reason)")
        }
        didActivateKeyboard = false
    }
    
    @objc private func cancelTapped() {
        deactivateKeyboard(reason: "cancelTapped")
        print("[KeywordNameEntryViewController] cancelTapped: Dismissing without saving")
        dismiss(animated: true)
    }
    
    @objc private func saveTapped() {
        deactivateKeyboard(reason: "saveTapped")
        
        let name = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            print("[KeywordNameEntryViewController][ERROR] saveTapped: Attempted to save empty keyword")
            let alert = UIAlertController(title: "Invalid Keyword", message: "Please enter a keyword name.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        print("[KeywordNameEntryViewController] saveTapped: Saving keyword \(name)")
        onSave?(name)
        dismiss(animated: true)
    }
}
