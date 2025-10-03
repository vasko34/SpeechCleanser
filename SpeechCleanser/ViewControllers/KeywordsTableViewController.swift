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
        tableView.tableFooterView = UIView()
        print("[KeywordsTableViewController] viewDidLoad: Initialized")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        keywords = KeywordStore.shared.load()
        tableView.reloadData()
        print("[KeywordsTableViewController] viewWillAppear: Reloaded with \(keywords.count) keywords")
    }
    
    @objc private func addWord() {
        let alert = UIAlertController(title: "New Keyword", message: "Enter the keyword name.", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Keyword name"
            textField.autocapitalizationType = .sentences
        }
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self = self else { return }
            guard let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                print("[KeywordsTableViewController][ERROR] addWord: Attempted to add empty keyword")
                return
            }
            
            let keyword = Keyword(name: value, isEnabled: true, variations: [])
            self.keywords.insert(keyword, at: 0)
            self.tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
            KeywordStore.shared.save(self.keywords)
            print("[KeywordsTableViewController] addWord: Added keyword \(value)")
        }
        
        alert.addAction(saveAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
        print("[KeywordsTableViewController] addWord: Presented keyword creation alert")
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
            KeywordStore.shared.save(self.keywords)
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
        KeywordStore.shared.deleteKeyword(withID: keyword.id)
        print("[KeywordsTableViewController] commitForRowAt: Deleted keyword \(keyword.name)")
    }
}
