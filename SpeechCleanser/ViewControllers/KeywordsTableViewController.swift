//
//  KeywordsTableViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit

class KeywordsTableViewController: UITableViewController {
    private let persistenceQueue = DispatchQueue(label: "KeywordsTableViewController.persistence", qos: .userInitiated)
    private var keywords: [Keyword] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Keywords"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addWord))
        tableView.register(KeywordCell.self, forCellReuseIdentifier: KeywordCell.reuseID)
        print("[KeywordsTableViewController] viewDidLoad: Initialized")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        keywords = KeywordStore.shared.load()
        tableView.reloadData()
        print("[KeywordsTableViewController] viewWillAppear: Reloaded with \(keywords.count) keywords")
    }
    
    @objc private func addWord() {
        // show alert to enter new word
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        print("[KeywordsTableViewController] numberOfRowsInSection: Returning \(keywords.count) rows")
        return keywords.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: KeywordCell.reuseID, for: indexPath) as? KeywordCell else { return UITableViewCell() }
        
        let keyword = keywords[indexPath.row]
        cell.configure(with: keyword)
        cell.onToggle = { [weak self] isOn in
            guard let self = self else { return }
            guard let index = self.keywords.firstIndex(where: { $0.id == keyword.id }) else { return }
            
            self.keywords[index].isEnabled = isOn
            let updated = self.keywords
            self.persistenceQueue.async {
                KeywordStore.shared.save(updated)
            }
            print("[KeywordsTableViewController] cellForRowAt: Toggled keyword \(keyword.name) to \(isOn)")
        }
        
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let keyword = keywords[indexPath.row]
        let viewController = VariationsTableViewController(keywordID: keyword.id)
        navigationController?.pushViewController(viewController, animated: true)
        print("[KeywordsTableViewController] didSelectRowAt: Selected keyword \(keyword.name)")
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        
        let keyword = keywords.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        print("[KeywordsTableViewController] commitForRowAt: Deleted keyword \(keyword.name)")
        
        persistenceQueue.async {
            // delete keyword
        }
    }
}
