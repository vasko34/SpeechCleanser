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
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        
        textField.placeholder = "Enter keyword name"
        textField.borderStyle = .roundedRect
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .done
        textField.delegate = self
        textField.enablesReturnKeyAutomatically = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        
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
        
        print("[KeywordNameEntryViewController] viewDidLoad: Ready for input")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard textField.window != nil, !textField.isFirstResponder else { return }
        
        if textField.becomeFirstResponder() {
            print("[KeywordNameEntryViewController] viewDidAppear: Activated text field")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignKeyboardIfNeeded(reason: "viewWillDisappear")
    }
    
    private func resignKeyboardIfNeeded(reason: String) {
        guard textField.isFirstResponder else { return }
        
        let result = textField.resignFirstResponder()
        print("[KeywordNameEntryViewController] resignKeyboardIfNeeded: Resigned text field via \(reason), resignation result: \(result)")
    }
    
    @objc private func cancelTapped() {
        resignKeyboardIfNeeded(reason: "cancelTapped")
        print("[KeywordNameEntryViewController] cancelTapped: Dismissing without saving")
        dismiss(animated: true)
    }
    
    @objc private func saveTapped() {
        resignKeyboardIfNeeded(reason: "saveTapped")
        
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

// MARK: - UITextFieldDelegate

extension KeywordNameEntryViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveTapped()
        return true
    }
}
