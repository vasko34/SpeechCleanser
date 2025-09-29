//
//  KeywordCell.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit

class KeywordCell: UITableViewCell {
    static let reuseID = String(describing: KeywordCell.self)
    
    private let nameLabel = UILabel()
    private let toggle = UISwitch()
    var onToggle: ((Bool) -> Void)?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        
        accessoryView = toggle
        nameLabel.font = .systemFont(ofSize: 17, weight: .regular)
        contentView.addSubview(nameLabel)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        ])
        
        toggle.addTarget(self, action: #selector(switched), for: .valueChanged)
        selectionStyle = .default
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setEnabledAppearance(_ enabled: Bool) {
        contentView.alpha = enabled ? 1.0 : 0.5
    }
    
    @objc private func switched() {
        onToggle?(toggle.isOn)
        setEnabledAppearance(toggle.isOn)
        print("[KeywordCell] switched: Keyword toggled to \(toggle.isOn)")
    }
    
    func configure(with keyword: Keyword) {
        nameLabel.text = keyword.name
        toggle.isOn = keyword.isEnabled
        setEnabledAppearance(keyword.isEnabled)
        print("[KeywordCell] configure: Displaying keyword \(keyword.name) enabled=\(keyword.isEnabled)")
    }
}
