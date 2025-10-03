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
    private let pavlokConfigButton = UIButton(type: .system)
    private let pavlokStatusLabel = UILabel()
    private var listeningObserver: NSObjectProtocol?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "SpeechCleanser"
        view.backgroundColor = .systemBackground
        
        toggleButton.setTitle("Start Background Listening", for: .normal)
        toggleButton.addTarget(self, action: #selector(toggleListening), for: .touchUpInside)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        
        manageWordsButton.setTitle("Custom Keywords", for: .normal)
        manageWordsButton.addTarget(self, action: #selector(openKeywordsTableViewController), for: .touchUpInside)
        manageWordsButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        
        pavlokConfigButton.setTitle("Configure Pavlok", for: .normal)
        pavlokConfigButton.addTarget(self, action: #selector(configurePavlok), for: .touchUpInside)
        pavlokConfigButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)

        pavlokStatusLabel.textAlignment = .center
        pavlokStatusLabel.textColor = .secondaryLabel
        pavlokStatusLabel.font = .systemFont(ofSize: 15, weight: .regular)
        updatePavlokStatus()

        [toggleButton, manageWordsButton, pavlokConfigButton, pavlokStatusLabel].forEach {
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
            pavlokStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24)
        ])
        
        listeningObserver = NotificationCenter.default.addObserver(forName: .speechDetectionStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateToggleButtonTitle()
        }
        
        print("[ViewController] viewDidLoad: UI configured")
    }
    
    deinit {
        if let observer = listeningObserver {
            NotificationCenter.default.removeObserver(observer)
            print("[ViewController] deinit: Removed listening observer")
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        updatePavlokStatus()
        updateToggleButtonTitle()
        print("[ViewController] viewWillAppear: Updated Pavlok status and toggle title")
    }
    
    private func updatePavlokStatus() {
        let configured = (PavlokService.shared.apiKey?.isEmpty == false)
        let intensity = PavlokService.shared.intensity
        pavlokStatusLabel.text = configured ? "Pavlok ready – intensity \(intensity)" : "Pavlok not configured"
        pavlokStatusLabel.textColor = configured ? .systemGreen : .systemRed
        print("[ViewController] updatePavlokStatus: Configured=\(configured) intensity=\(intensity)")
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        print("[ViewController] showAlert: Presented alert with title \(title)")
    }
    
    private func updateToggleButtonTitle() {
        let isListening = SpeechDetectionService.shared.isListening
        let title = isListening ? "Stop Background Listening" : "Start Background Listening"
        toggleButton.setTitle(title, for: .normal)
        print("[ViewController] updateToggleButtonTitle: Listening state=\(isListening)")
    }
    
    @objc private func toggleListening() {
        let manager = SpeechDetectionService.shared
        if manager.isListening {
            manager.stopListening()
            updateToggleButtonTitle()
            print("[ViewController] toggleListening: Requested stop")
        } else {
            manager.startListening { [weak self] success in
                DispatchQueue.main.async {
                    self?.updateToggleButtonTitle()
                    if success {
                        print("[ViewController] toggleListening: Listening started successfully")
                    } else {
                        self?.showAlert(title: "Microphone", message: "Unable to start background listening. Please check permissions and model availability.")
                        print("[ViewController][ERROR] toggleListening: Failed to start listening")
                    }
                }
            }
        }
    }
    
    @objc private func openKeywordsTableViewController() {
        let viewController = KeywordsTableViewController()
        navigationController?.pushViewController(viewController, animated: true)
        print("[ViewController] openKeywordsTableViewController: Navigated to keywords list")
    }
    
    @objc private func configurePavlok() {
        let controller = PavlokSettingsViewController(apiKey: PavlokService.shared.apiKey, intensity: PavlokService.shared.intensity)
        controller.onSave = { [weak self] apiKey, intensity in
            PavlokService.shared.apiKey = apiKey
            PavlokService.shared.intensity = intensity
            self?.updatePavlokStatus()
            print("[ViewController] configurePavlok: Saved settings")
        }
        
        let navigation = UINavigationController(rootViewController: controller)
        present(navigation, animated: true)
        print("[ViewController] configurePavlok: Presented settings controller")
    }
}
