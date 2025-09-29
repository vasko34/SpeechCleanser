//
//  PavlokSettingsViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit

class PavlokSettingsViewController: UIViewController {
    private let apiKeyField = UITextField()
    private let intensityField = UITextField()
    private let infoLabel = UILabel()
    private let initialAPIKey: String?
    private let initialIntensity: Int
    
    var onSave: ((String?, Int) -> Void)?
    
    init(apiKey: String?, intensity: Int) {
        initialAPIKey = apiKey
        initialIntensity = intensity
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { nil }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Pavlok Settings"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        
        infoLabel.text = "Provide your Pavlok API token and zap intensity (10-100)."
        infoLabel.font = .systemFont(ofSize: 15)
        infoLabel.numberOfLines = 0
        
        apiKeyField.placeholder = "API Token"
        apiKeyField.borderStyle = .roundedRect
        apiKeyField.autocapitalizationType = .none
        apiKeyField.text = initialAPIKey
        
        intensityField.placeholder = "Intensity"
        intensityField.borderStyle = .roundedRect
        intensityField.keyboardType = .numberPad
        intensityField.text = String(initialIntensity)
        
        [infoLabel, apiKeyField, intensityField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            apiKeyField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            apiKeyField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            apiKeyField.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 16),
            apiKeyField.heightAnchor.constraint(equalToConstant: 44),
            
            intensityField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            intensityField.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 16),
            intensityField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            intensityField.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        print("[PavlokSettingsViewController] viewDidLoad: Loaded with API key present=\(initialAPIKey?.isEmpty == false)")
    }
    
    @objc private func cancelTapped() {
        view.endEditing(true)
        print("[PavlokSettingsViewController] cancelTapped: Dismissing without saving")
        dismiss(animated: true)
    }
    
    @objc private func saveTapped() {
        view.endEditing(true)
        
        let trimmedToken = apiKeyField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawIntensity = intensityField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = Int(rawIntensity) ?? initialIntensity
        let clampedIntensity = max(10, min(100, value))
        
        if clampedIntensity != value {
            print("[PavlokSettingsViewController] saveTapped: Adjusted intensity from \(value) to \(clampedIntensity)")
        }
        
        onSave?(trimmedToken, clampedIntensity)
        print("[PavlokSettingsViewController] saveTapped: Saved settings")
        dismiss(animated: true)
    }
}
