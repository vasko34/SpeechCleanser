//
//  ViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 28.09.25.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    private let modelToggle = UISegmentedControl(items: ["Medium", "Large"])
    private let toggleButton = UIButton(type: .system)
    private let manageWordsButton = UIButton(type: .system)
    private let pavlokConfigButton = UIButton(type: .system)
    private let pavlokStatusLabel = UILabel()
    private let listeningIndicatorLabel = UILabel()
    private var listeningObserver: NSObjectProtocol?
    private var modelObserver: NSObjectProtocol?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "SpeechCleanser"
        view.backgroundColor = .systemBackground
        
        modelToggle.selectedSegmentIndex = SpeechDetectionService.shared.selectedModelSize == .medium ? 0 : 1
        modelToggle.addTarget(self, action: #selector(modelSelectionChanged), for: .valueChanged)
        modelToggle.setContentHuggingPriority(.required, for: .vertical)
        
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
        
        listeningIndicatorLabel.font = .systemFont(ofSize: 14, weight: .medium)
        listeningIndicatorLabel.textAlignment = .center
        listeningIndicatorLabel.textColor = .systemOrange
        listeningIndicatorLabel.isHidden = true
        
        [modelToggle, toggleButton, listeningIndicatorLabel, manageWordsButton, pavlokConfigButton, pavlokStatusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        
        NSLayoutConstraint.activate([
            modelToggle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            modelToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            modelToggle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            
            toggleButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            toggleButton.topAnchor.constraint(equalTo: modelToggle.bottomAnchor, constant: 24),
            toggleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            
            listeningIndicatorLabel.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 12),
            listeningIndicatorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            listeningIndicatorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            manageWordsButton.topAnchor.constraint(equalTo: listeningIndicatorLabel.bottomAnchor, constant: 32),
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
        
        modelObserver = NotificationCenter.default.addObserver(forName: .whisperModelPreferenceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateModelSelection()
        }
        
        print("[ViewController] viewDidLoad: UI configured")
    }
    
    deinit {
        if let observer = listeningObserver {
            NotificationCenter.default.removeObserver(observer)
            print("[ViewController] deinit: Removed listening observer")
        }
        
        if let observer = modelObserver {
            NotificationCenter.default.removeObserver(observer)
            print("[ViewController] deinit: Removed model observer")
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        updatePavlokStatus()
        updateToggleButtonTitle()
        updateModelSelection()
        updateModelToggleEnabled()
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
        updateModelToggleEnabled()
        updateListeningIndicator()
        print("[ViewController] updateToggleButtonTitle: Listening state=\(isListening)")
    }
    
    private func updateModelSelection() {
        let size = SpeechDetectionService.shared.selectedModelSize
        modelToggle.selectedSegmentIndex = (size == .medium) ? 0 : 1
        print("[ViewController] updateModelSelection: Selected model=\(size)")
    }
    
    private func updateModelToggleEnabled() {
        let isListening = SpeechDetectionService.shared.isListening
        modelToggle.isEnabled = !isListening
        print("[ViewController] updateModelToggleEnabled: Enabled=\(!isListening)")
    }
    
    private func updateListeningIndicator() {
        let isListening = SpeechDetectionService.shared.isListening
        listeningIndicatorLabel.isHidden = !isListening
        listeningIndicatorLabel.text = isListening ? "Listening in background…" : nil
        print("[ViewController] updateListeningIndicator: Visible=\(isListening)")
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
    
    @objc private func modelSelectionChanged() {
        let selectedIndex = modelToggle.selectedSegmentIndex
        let size: ModelSize = selectedIndex == 0 ? .medium : .large
        SpeechDetectionService.shared.updatePreferredModel(size: size)
        print("[ViewController] modelSelectionChanged: Updated preferred model to \(size)")
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
