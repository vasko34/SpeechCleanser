//
//  VariationsTableViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit
import AVFoundation

class VariationsTableViewController: UITableViewController {
    private let keywordID: UUID
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var recordStart: Date?
    private var recordAlert: UIAlertController?
    private var recordURL: URL?
    private var keyword: Keyword?
    private var resumeListeningAfterRecording = false
    
    init(keywordID: UUID) {
        self.keywordID = keywordID
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = keyword?.name
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addVariation))
        tableView.register(VariationCell.self, forCellReuseIdentifier: VariationCell.reuseID)
        print("[VariationsTableViewController] viewDidLoad: Configured for keywordID \(keywordID.uuidString)")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        reloadKeyword()
        print("[VariationsTableViewController] viewWillAppear: Reloaded keyword data")
    }
    
    private func reloadKeyword() {
        let all = KeywordStore.shared.load()
        self.keyword = all.first(where: { $0.id == keywordID })
        self.title = keyword?.name
        self.tableView.reloadData()
        print("[VariationsTableViewController] reloadKeyword: Keyword has \(self.keyword?.variations.count ?? 0) variations")
    }
    
    private func beginRecordingFlow() {
        resumeListeningAfterRecording = AudioManager.shared.running
        if resumeListeningAfterRecording {
            AudioManager.shared.stop()
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            showAlert(title: "Audio Error", message: error.localizedDescription)
            print("[VariationsTableViewController][ERROR] beginRecordingFlow: Unable to start recording session with error: \(error.localizedDescription)")
            return
        }
        
        let filename = "variation_\(UUID().uuidString).m4a"
        let url = KeywordStore.fileURL(for: filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.prepareToRecord()
            rec.isMeteringEnabled = true
            rec.record()
            self.recorder = rec
            self.recordStart = Date()
            self.recordURL = url
            
            print("[VariationsTableViewController] beginRecordingFlow: Recording to \(url.lastPathComponent)")
            let alert = UIAlertController(title: "Recording…", message: "Speak your variation and tap Stop.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Stop", style: .destructive, handler: { [weak self] _ in
                self?.finishRecording()
            }))
            
            self.recordAlert = alert
            self.present(alert, animated: true)
        } catch {
            showAlert(title: "Record Error", message: error.localizedDescription)
            print("[VariationsTableViewController][ERROR] beginRecordingFlow: Failed to begin recording with error: \(error.localizedDescription)")
        }
    }
    
    private func finishRecording() {
        recorder?.stop()
        let start = recordStart ?? Date()
        let duration = Date().timeIntervalSince(start)
        let actualDuration = recorder?.currentTime ?? duration
        let fileURL = recordURL
        
        recorder = nil
        recordStart = nil
        recordURL = nil
        recordAlert?.dismiss(animated: true)
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[VariationsTableViewController][ERROR] finishRecording: Failed to deactivate recording session with error: \(error.localizedDescription)")
        }
        
        guard let url = fileURL else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var list = KeywordStore.shared.load()
            guard let self = self else { return }
            guard let idx = list.firstIndex(where: { $0.id == self.keywordID }) else {
                print("[VariationsTableViewController][ERROR] finishRecording: Keyword missing during save")
                return
            }
            
            let analysis = AudioFingerprint.fromFile(url: url)
            var kword = list[idx]
            let relativePath = url.lastPathComponent
            let variation = Variation(filePath: relativePath, duration: actualDuration, fingerprint: analysis.fingerprint)
            kword.variations.append(variation)
            list[idx] = kword
            KeywordStore.shared.save(list)
            
            DispatchQueue.main.async {
                self.keyword = kword
                self.tableView.reloadData()
                AudioManager.shared.reloadKeywords()
                print("[VariationsTableViewController] finishRecording: Saved new variation for keyword \(kword.name)")
            }
        }
        
        if resumeListeningAfterRecording {
            resumeListeningAfterRecording = false
            AudioManager.shared.start()
            print("[VariationsTableViewController] finishRecording: Resumed background listening")
        }
    }
    
    private func play(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            print("[VariationsTableViewController] play: Playing variation from \(url.lastPathComponent)")
        } catch {
            showAlert(title: "Playback Error", message: error.localizedDescription)
            print("[VariationsTableViewController][ERROR] play: Failed to play variation with error: \(error.localizedDescription)")
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        print("[VariationsTableViewController] showAlert: Presented alert with title \(title)")
    }
    
    @objc private func addVariation() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.showAlert(title: "Microphone Denied", message: "Enable mic access in Settings.")
                    print("[VariationsTableViewController][ERROR] addVariation: Microphone permission denied")
                    return
                }
                
                self?.beginRecordingFlow()
                print("[VariationsTableViewController] addVariation: Microphone permission granted")
            }
        }
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let count = keyword?.variations.count ?? 0
        print("[VariationsTableViewController] numberOfRowsInSection: Returning \(count) rows")
        return count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: VariationCell.reuseID, for: indexPath) as? VariationCell, let varItem = keyword?.variations[indexPath.row] else { return UITableViewCell() }
        
        cell.configure(with: varItem, index: indexPath.row + 1)
        print("[VariationsTableViewController] cellForRowAt: Configured cell for index \(indexPath.row)")
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let varItem = keyword?.variations[indexPath.row] else { return }
        
        let url = KeywordStore.fileURL(for: varItem.filePath)
        play(url: url)
        print("[VariationsTableViewController] didSelectRowAt: Selected variation index \(indexPath.row)")
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        guard var keyword = keyword else { return }
        
        let variation = keyword.variations[indexPath.row]
        let fileURL = KeywordStore.fileURL(for: variation.filePath)
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            print("[VariationsTableViewController] commitForRowAt: Removed file \(variation.filePath)")
        } catch {
            print("[VariationsTableViewController][ERROR] commitForRowAt: FileManager failed to remove item with error: \(error.localizedDescription)")
        }
        
        keyword.variations.remove(at: indexPath.row)
        var list = KeywordStore.shared.load()
        if let index = list.firstIndex(where: { $0.id == keywordID }) {
            list[index] = keyword
            KeywordStore.shared.save(list)
        }
        
        self.keyword = keyword
        tableView.deleteRows(at: [indexPath], with: .automatic)
        AudioManager.shared.reloadKeywords()
        print("[VariationsTableViewController] commitForRowAt: Deleted variation at index \(indexPath.row)")
    }
}
