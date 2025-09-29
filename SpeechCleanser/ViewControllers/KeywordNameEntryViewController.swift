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
            self?.handleWillResignActive()
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activateKeyboardIfNeeded()
        }
        
        print("[KeywordNameEntryViewController] viewDidLoad: Ready for input")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateKeyboardIfNeeded()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if textField.isFirstResponder {
            textField.resignFirstResponder()
            print("[KeywordNameEntryViewController] viewWillDisappear: Resigned text field")
        }
        didActivateKeyboard = false
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func activateKeyboardIfNeeded() {
        guard !didActivateKeyboard, view.window != nil else { return }
        
        if !textField.isFirstResponder {
            didActivateKeyboard = true
            textField.becomeFirstResponder()
            print("[KeywordNameEntryViewController] activateKeyboardIfNeeded: Activated text field")
        }
    }
    
    @objc private func handleWillResignActive() {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
            print("[KeywordNameEntryViewController] handleWillResignActive: Resigned text field")
        }
        didActivateKeyboard = false
    }
    
    @objc private func cancelTapped() {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
        
        print("[KeywordNameEntryViewController] cancelTapped: Dismissing without saving")
        dismiss(animated: true)
    }
    
    @objc private func saveTapped() {
        if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
        
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
