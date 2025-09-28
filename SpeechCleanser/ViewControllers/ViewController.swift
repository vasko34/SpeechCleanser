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
        
        [toggleButton, manageWordsButton, levelLabel].forEach {
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
            
            levelLabel.topAnchor.constraint(equalTo: manageWordsButton.bottomAnchor, constant: 16),
            levelLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            levelLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24)
        ])
        
        AudioManager.shared.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.levelLabel.text = String(format: "Level: %.3f", level)
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    @objc private func toggleListening() {
        if AudioManager.shared.running {
            AudioManager.shared.stop()
            toggleButton.setTitle("Start Background Listening", for: .normal)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        AudioManager.shared.start()
                        self?.toggleButton.setTitle("Stop Background Listening", for: .normal)
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
}
