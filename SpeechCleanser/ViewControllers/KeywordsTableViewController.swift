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
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        keywords = KeywordStore.shared.load()
        tableView.reloadData()
    }
    
    @objc private func addWord() {
        let alert = UIAlertController(title: "New Word", message: "Enter a name for the keyword", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "Enter keyword"
            tf.autocapitalizationType = .none
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default, handler: { [weak self] _ in
            guard let self = self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            
            var list = KeywordStore.shared.load()
            list.append(Keyword(name: name, isEnabled: true, variations: []))
            KeywordStore.shared.save(list)
            self.keywords = list
            self.tableView.reloadData()
        }))
        
        present(alert, animated: true)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        keywords.count
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
        }
        
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let keyword = keywords[indexPath.row]
        let viewController = VariationsTableViewController(keywordID: keyword.id)
        navigationController?.pushViewController(viewController, animated: true)
    }
}
