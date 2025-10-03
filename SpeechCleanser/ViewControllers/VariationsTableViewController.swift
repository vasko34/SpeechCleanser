//
//  VariationsTableViewController.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit

class VariationsTableViewController: UITableViewController {
    private let persistenceQueue = DispatchQueue(label: "VariationsTableViewController.persistence", qos: .userInitiated)
    private let keywordID: UUID
    private var keyword: Keyword?
    
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
    
    private func presentVariationEditor(title: String, message: String, defaultValue: String?, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Variation"
            textField.autocapitalizationType = .none
            textField.text = defaultValue
        }
        
        let saveAction = UIAlertAction(title: "Save", style: .default) { _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                print("[VariationsTableViewController][ERROR] presentVariationEditor: Attempted to save empty variation")
                return
            }
            completion(text)
        }
        
        alert.addAction(saveAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
        print("[VariationsTableViewController] presentVariationEditor: Presented editor titled \(title)")
    }
    
    private func persist(keyword: Keyword) {
        let keywordCopy = keyword
        persistenceQueue.async {
            KeywordStore.shared.update(keywordCopy)
        }
    }
    
    @objc private func addVariation() {
        presentVariationEditor(title: "Add Variation", message: "Enter a spoken variation for this keyword.", defaultValue: nil) { [weak self] value in
            guard let self = self else { return }
            guard var keyword = self.keyword else { return }
            
            let variation = Variation(name: value)
            keyword.variations.insert(variation, at: 0)
            self.keyword = keyword
            
            self.tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic)
            self.persist(keyword: keyword)
            print("[VariationsTableViewController] addVariation: Added variation \(value)")
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
        guard let variation = keyword?.variations[indexPath.row] else { return }
        
        presentVariationEditor(title: "Edit Variation", message: "Update the variation text.", defaultValue: variation.name) { [weak self] value in
            guard let self = self else { return }
            guard var keyword = self.keyword else { return }
            
            keyword.variations[indexPath.row].name = value
            self.keyword = keyword
            self.tableView.reloadRows(at: [indexPath], with: .automatic)
            self.persist(keyword: keyword)
            print("[VariationsTableViewController] didSelectRowAt: Updated variation at index \(indexPath.row)")
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        guard let keyword = keyword else { return }
        
        var updatedKeyword = keyword
        let removed = updatedKeyword.variations.remove(at: indexPath.row)
        self.keyword = updatedKeyword
        tableView.deleteRows(at: [indexPath], with: .automatic)
        print("[VariationsTableViewController] commitForRowAt: Deleted variation \(removed.name) at index \(indexPath.row)")

        persist(keyword: updatedKeyword)
    }
}
