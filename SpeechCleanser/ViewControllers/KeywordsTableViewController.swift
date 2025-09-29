//
//  KeywordsTableViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit

class KeywordsTableViewController: UITableViewController {
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
        let controller = KeywordNameEntryViewController()
        controller.onSave = { [weak self] name in
            guard let self else { return }
            
            var list = KeywordStore.shared.load()
            list.append(Keyword(name: name, isEnabled: true, variations: []))
            KeywordStore.shared.save(list)
            self.keywords = list
            AudioManager.shared.reloadKeywords()
            self.tableView.reloadData()
            print("[KeywordsTableViewController] addWord: Added keyword \(name)")
        }
        
        let navigation = UINavigationController(rootViewController: controller)
        present(navigation, animated: true)
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
            
            var list = self.keywords
            list[indexPath.row].isEnabled = isOn
            self.keywords = list
            KeywordStore.shared.save(list)
            AudioManager.shared.reloadKeywords()
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
        
        var list = KeywordStore.shared.load()
        let keyword = list.remove(at: indexPath.row)
        KeywordStore.shared.save(list)
        keywords = list
        tableView.deleteRows(at: [indexPath], with: .automatic)
        AudioManager.shared.reloadKeywords()
        print("[KeywordsTableViewController] commitForRowAt: Deleted keyword \(keyword.name)")
        
        for variation in keyword.variations {
            let fileURL = KeywordStore.fileURL(for: variation.filePath)
            
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("[KeywordsTableViewController] commitForRowAt: Removed file \(variation.filePath)")
            } catch {
                print("[KeywordsTableViewController][ERROR] commitForRowAt: FileManager failed to remove item with error: \(error.localizedDescription)")
            }
        }
    }
}
