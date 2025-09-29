//
//  ViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 28.09.25.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    private let toggleButton = UIButton(type: .system)
    private let manageWordsButton = UIButton(type: .system)
    private let levelLabel = UILabel()
    private let pavlokConfigButton = UIButton(type: .system)
    private let pavlokStatusLabel = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "SpeechCleanser"
        view.backgroundColor = .systemBackground
        
        toggleButton.setTitle("Start Background Listening", for: .normal)
        toggleButton.addTarget(self, action: #selector(toggleListening), for: .touchUpInside)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        
        manageWordsButton.setTitle("Custom Keywords", for: .normal)
        manageWordsButton.addTarget(self, action: #selector(openCustomWords), for: .touchUpInside)
        manageWordsButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        
        levelLabel.text = "Level: —"
        levelLabel.textAlignment = .center
        levelLabel.textColor = .secondaryLabel
        
        pavlokConfigButton.setTitle("Configure Pavlok", for: .normal)
        pavlokConfigButton.addTarget(self, action: #selector(configurePavlok), for: .touchUpInside)
        pavlokConfigButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)

        pavlokStatusLabel.textAlignment = .center
        pavlokStatusLabel.textColor = .secondaryLabel
        pavlokStatusLabel.font = .systemFont(ofSize: 15, weight: .regular)
        updatePavlokStatus()

        [toggleButton, manageWordsButton, pavlokConfigButton, pavlokStatusLabel, levelLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            toggleButton.bottomAnchor.constraint(equalTo: manageWordsButton.topAnchor, constant: -16),
            toggleButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            toggleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            
            manageWordsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            manageWordsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            manageWordsButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            pavlokConfigButton.topAnchor.constraint(equalTo: manageWordsButton.bottomAnchor, constant: 16),
            pavlokConfigButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            pavlokConfigButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            pavlokStatusLabel.topAnchor.constraint(equalTo: pavlokConfigButton.bottomAnchor, constant: 8),
            pavlokStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            pavlokStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            levelLabel.topAnchor.constraint(equalTo: pavlokStatusLabel.bottomAnchor, constant: 12),
            levelLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            levelLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24)
        ])
        
        AudioManager.shared.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.levelLabel.text = String(format: "Level: %.3f", level)
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        updatePavlokStatus()
        updateToggleButtonTitle()
    }
    
    private func updatePavlokStatus() {
        let configured = (PavlokService.shared.apiKey?.isEmpty == false)
        let intensity = PavlokService.shared.intensity
        pavlokStatusLabel.text = configured ? "Pavlok ready – intensity \(intensity)" : "Pavlok not configured"
        pavlokStatusLabel.textColor = configured ? .systemGreen : .systemRed
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func updateToggleButtonTitle() {
        let title = AudioManager.shared.running ? "Stop Background Listening" : "Start Background Listening"
        toggleButton.setTitle(title, for: .normal)
    }
    
    @objc private func toggleListening() {
        if AudioManager.shared.running {
            AudioManager.shared.stop()
            updateToggleButtonTitle()
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        AudioManager.shared.start()
                        self?.updateToggleButtonTitle()
                    } else {
                        self?.showAlert(title: "Microphone Denied", message: "Enable mic access in Settings.")
                    }
                }
            }
        }
    }
    
    @objc private func openCustomWords() {
        let viewController = KeywordsTableViewController()
        navigationController?.pushViewController(viewController, animated: true)
    }
    
    @objc private func configurePavlok() {
        let alert = UIAlertController(title: "Pavlok Settings", message: "Provide your Pavlok API token and zap intensity.", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "API Token"
            textField.text = PavlokService.shared.apiKey
        }
        alert.addTextField { textField in
            textField.placeholder = "Intensity (10-100)"
            textField.keyboardType = .numberPad
            textField.text = String(PavlokService.shared.intensity)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { [weak self] _ in
            let token = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let intensityText = alert.textFields?.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            PavlokService.shared.apiKey = token
            if let value = Int(intensityText) {
                PavlokService.shared.intensity = value
            }
            self?.updatePavlokStatus()
        }))
        
        present(alert, animated: true)
    }
}
