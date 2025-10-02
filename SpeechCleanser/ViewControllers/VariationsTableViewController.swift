//
//  VariationsTableViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit
import AVFoundation

class VariationsTableViewController: UITableViewController {
    private let persistenceQueue = DispatchQueue(label: "VariationsTableViewController.persistence", qos: .userInitiated)
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
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        print("[VariationsTableViewController] showAlert: Presented alert with title \(title)")
    }
    
    @objc private func addVariation() {
        
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
        // edit variation
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        guard let keyword = keyword else { return }
        
        let updatedKeyword = keyword
        self.keyword = updatedKeyword
        tableView.deleteRows(at: [indexPath], with: .automatic)
        print("[VariationsTableViewController] commitForRowAt: Deleted variation at index \(indexPath.row)")
        
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            
            var list = KeywordStore.shared.load()
            if let index = list.firstIndex(where: { $0.id == self.keywordID }) {
                list[index] = updatedKeyword
                KeywordStore.shared.save(list)
            }
        }
    }
}
