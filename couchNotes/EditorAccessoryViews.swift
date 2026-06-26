//
//  EditorAccessoryViews.swift
//  couchNotes
//
//  MarkdownTextView.swift から分割（純粋なコード移動・ロジック変更なし）。
//

import UIKit

// MARK: - SuggestionPanelView

/// キーボードの真上に浮かぶ、Wiki リンク候補の縦リスト。
/// inputAccessoryView ではなくアプリのウィンドウに重ねるので、IME を一切触らない。
final class SuggestionPanelView: UIView {
    var onSelect: ((NoteItem) -> Void)?

    private let blur   = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let scroll = UIScrollView()
    private let stack  = UIStackView()

    static let rowHeight: CGFloat = 36
    private static let maxVisibleRows = 4
    /// 現在の候補数に応じた表示高さ。
    private(set) var preferredHeight: CGFloat = rowHeight

    init() {
        super.init(frame: .zero)
        // 上に向かって持ち上がる影（角丸は内側の blur 側でクリップ）
        layer.shadowColor   = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius  = 10
        layer.shadowOffset  = CGSize(width: 0, height: -3)

        blur.layer.cornerRadius  = 14
        blur.layer.cornerCurve   = .continuous
        blur.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // 上だけ角丸
        blur.clipsToBounds = true
        addSubview(blur)
        blur.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        blur.contentView.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
        ])

        stack.axis = .vertical
        stack.spacing = 0
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(with notes: [NoteItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, note) in notes.enumerated() {
            if i > 0 {
                let sep = UIView()
                sep.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(sep)
            }
            stack.addArrangedSubview(makeRow(note, highlighted: i == 0))
        }
        let rows = CGFloat(min(notes.count, Self.maxVisibleRows))
        preferredHeight = max(Self.rowHeight, rows * Self.rowHeight)
        scroll.setContentOffset(.zero, animated: false)
    }

    private func makeRow(_ note: NoteItem, highlighted: Bool) -> UIView {
        let row = UIControl()
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        if highlighted { row.backgroundColor = UIColor.tintColor.withAlphaComponent(0.14) }

        let icon = UIImageView(image: UIImage(systemName: "doc"))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = note.shortTitle
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail

        let h = UIStackView(arrangedSubviews: [icon, label])
        h.axis = .horizontal
        h.spacing = 8
        h.alignment = .center
        h.isUserInteractionEnabled = false
        row.addSubview(h)
        h.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            h.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        row.addAction(UIAction { [weak self] _ in self?.onSelect?(note) }, for: .touchUpInside)
        return row
    }
}

// MARK: - KeyboardToolbarView

/// ソフトウェアキーボード上部の常駐ツールバー。
/// 後でボタンを追加しやすいように、内部で UIStackView を使った横スクロール構造にしている。
final class KeyboardToolbarView: UIView {
    var onPaste:           (() -> Void)?
    var onUploadImage:     (() -> Void)?
    var onDoubleBracket:   (() -> Void)?
    var onListToggle:      (() -> Void)?
    var onMoveLineUp:      (() -> Void)?
    var onMoveLineDown:    (() -> Void)?
    var onDecreaseIndent:  (() -> Void)?
    var onIncreaseIndent:  (() -> Void)?

    private let stack = UIStackView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))

        stack.axis         = .horizontal
        stack.spacing      = 5
        stack.alignment    = .fill
        stack.distribution = .fillEqually   // 8つを画面幅に等分（横スクロールなし）
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])

        // ボタン追加（左から: ペースト・写真・[[]]・チェック・行↑・行↓・アウトデント・インデント）
        stack.addArrangedSubview(makeButton(systemImage: "clipboard")          { [weak self] in self?.onPaste?() })
        stack.addArrangedSubview(makeButton(systemImage: "photo.badge.plus")   { [weak self] in self?.onUploadImage?() })
        stack.addArrangedSubview(makeButton(title: "[[ ]]")                    { [weak self] in self?.onDoubleBracket?() })
        stack.addArrangedSubview(makeButton(systemImage: "checklist")          { [weak self] in self?.onListToggle?() })
        stack.addArrangedSubview(makeButton(systemImage: "arrow.up")           { [weak self] in self?.onMoveLineUp?() })
        stack.addArrangedSubview(makeButton(systemImage: "arrow.down")         { [weak self] in self?.onMoveLineDown?() })
        stack.addArrangedSubview(makeButton(systemImage: "arrow.left.to.line")  { [weak self] in self?.onDecreaseIndent?() })
        stack.addArrangedSubview(makeButton(systemImage: "arrow.right.to.line") { [weak self] in self?.onIncreaseIndent?() })
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(title: String? = nil,
                            systemImage: String? = nil,
                            action: @escaping () -> Void) -> UIButton {
        // 各ボタンに薄い角丸背景を付け、境界（タップ範囲）が分かるようにする。背景は薄め。
        var cfg = UIButton.Configuration.filled()
        if let title {
            cfg.title = title
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 13, weight: .medium)
                return out
            }
        }
        if let systemImage {
            cfg.image = UIImage(systemName: systemImage)
            cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        }
        cfg.baseForegroundColor = .label
        cfg.baseBackgroundColor = .quaternarySystemFill   // さらに薄く
        cfg.cornerStyle  = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)

        let btn = UIButton(configuration: cfg)
        btn.titleLabel?.numberOfLines = 1   // [[ ]] を1行に
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }
}

// MARK: - AccessoryContainerView

/// inputAccessoryView として一度だけ attach されるコンテナ（常駐ツールバー）。
/// 候補はキーボード上の浮動パネル（SuggestionPanelView）で出すので、ここでは
/// 候補中にツールバーを隠すだけ。inputAccessoryView 自体を入れ替えないため IME は維持される。
final class AccessoryContainerView: UIInputView {
    let toolbar = KeyboardToolbarView()
    private static let barHeight: CGFloat = 44
    private var heightConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: AccessoryContainerView.barHeight),
                   inputViewStyle: .keyboard)
        // 高さを Auto Layout で持たせると、制約を変えるだけでキーボード側が追従し、
        // reloadInputViews（＝IME破壊）なしにバーを畳める。
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: AccessoryContainerView.barHeight)
        heightConstraint.isActive = true

        // キーボード標準の濃い灰色を、薄い背景で覆う
        let bg = UIView()
        bg.backgroundColor = .secondarySystemBackground
        addSubview(bg)
        bg.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: AccessoryContainerView.barHeight),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 候補表示中はツールバー自体を畳んで消す（高さ0）。候補は浮動パネルで表示。
    func setSuggesting(_ on: Bool) {
        toolbar.isHidden = on
        heightConstraint.constant = on ? 0 : AccessoryContainerView.barHeight
    }
}

// MARK: - BacklinksFooterView

/// 本文末尾に表示するバックリンク（リンク元）一覧。UITextView のスクロール領域に差し込む。
final class BacklinksFooterView: UIView {
    var onTap: ((String) -> Void)?

    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        stack.axis    = .vertical
        stack.spacing = 4
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with backlinks: [NoteItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(10, after: separator)

        let header = UILabel()
        header.text      = "リンク元 (\(backlinks.count))"
        header.font      = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabel
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)

        for note in backlinks {
            stack.addArrangedSubview(makeRow(note))
        }
    }

    private func makeRow(_ note: NoteItem) -> UIView {
        let control = UIControl()
        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 2
        inner.isUserInteractionEnabled = false
        control.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: control.topAnchor, constant: 6),
            inner.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -6),
            inner.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: control.trailingAnchor),
        ])

        let title = UILabel()
        title.text          = note.shortTitle
        title.font          = .systemFont(ofSize: 15, weight: .medium)
        title.textColor     = .systemBlue
        title.numberOfLines = 1
        inner.addArrangedSubview(title)

        if let preview = note.preview, !preview.isEmpty {
            let body = UILabel()
            body.text          = preview
            body.font          = .systemFont(ofSize: 12)
            body.textColor     = .secondaryLabel
            body.numberOfLines = 2
            inner.addArrangedSubview(body)
        }

        control.addAction(UIAction { [weak self] _ in self?.onTap?(note.id) }, for: .touchUpInside)
        return control
    }
}
