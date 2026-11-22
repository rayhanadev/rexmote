import AppKit

final class PaneContent: NSView {
    enum Screen: Equatable {
        case desktop
        case credential(host: String, prompt: String)
        case status(title: String, detail: String, action: String?)
    }

    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    let desktop = DesktopView()
    let password = NSSecureTextField()
    var primaryAction: (() -> Void)?
    private let scroll = NSScrollView()
    private let document = Document()
    private let stack = NSStackView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let field = NSView()
    private let button = NSButton()
    private lazy var stackWidth = stack.widthAnchor.constraint(equalToConstant: 260)
    private lazy var buttonWidth = button.widthAnchor.constraint(equalToConstant: 72)
    private var screen: Screen?
    private var palette = RexPalette()
    private var nextThemeCheck: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(desktop)
        addSubview(scroll)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.addSubview(stack)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [heading, detail, field, button] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(12, after: detail)
        stack.setCustomSpacing(10, after: field)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        detail.font = .systemFont(ofSize: NSFont.systemFontSize)
        for label in [heading, detail] {
            label.alignment = .center
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.addSubview(password)
        password.translatesAutoresizingMaskIntoConstraints = false
        password.font = detail.font
        password.isBezeled = false
        password.drawsBackground = false
        password.target = self
        password.action = #selector(submit)
        button.target = self
        button.action = #selector(submit)
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        buttonWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stackWidth, stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor), field.heightAnchor.constraint(equalToConstant: 30),
            password.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 8),
            password.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8),
            password.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            buttonWidth, button.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func refreshTheme() {
        guard screen != .desktop else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextThemeCheck else { return }
        nextThemeCheck = now + 1
        let next = RexPalette.current(effectiveAppearance)
        if next != palette { applyTheme(next) }
    }

    private func applyTheme(_ next: RexPalette? = nil) {
        palette = next ?? RexPalette.current(effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = palette.background.cgColor
            heading.textColor = palette.primary
            detail.textColor = palette.secondary
            password.textColor = palette.primary
            if let placeholder = password.placeholderString ?? password.placeholderAttributedString?.string {
                password.placeholderAttributedString = NSAttributedString(
                    string: placeholder, attributes: [.foregroundColor: palette.secondary])
            }
            field.layer?.backgroundColor = palette.field.cgColor
            field.layer?.borderColor = palette.border.cgColor
            field.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 1)
            button.contentTintColor = palette.onAccent
            button.layer?.backgroundColor = palette.accent.cgColor
        }
    }

    var preferredResponder: NSResponder? {
        if screen == .desktop { return desktop }
        if !field.isHidden { return password }
        return button.isHidden ? nil : button
    }

    func show(_ next: Screen) {
        guard next != screen else { return }
        screen = next
        desktop.isHidden = next != .desktop
        scroll.isHidden = next == .desktop
        defer {
            if let window, window.isKeyWindow { window.makeFirstResponder(preferredResponder) }
        }
        switch next {
        case .desktop: return
        case .credential(let host, let prompt):
            heading.stringValue = "Sign in to " + host
            let passphrase = prompt.localizedCaseInsensitiveContains("passphrase")
            let passwordPrompt = prompt.localizedCaseInsensitiveContains("password")
            if passphrase { password.placeholderString = "SSH key passphrase" }
            else if passwordPrompt { password.placeholderString = "Password" }
            else { password.placeholderString = "Response" }
            password.setAccessibilityLabel(password.placeholderString)
            detail.stringValue = passphrase || passwordPrompt ? "" : prompt
            field.isHidden = false
            button.title = "Sign In"
        case .status(let title, let message, let action):
            heading.stringValue = title
            detail.stringValue = message
            field.isHidden = true
            button.title = action ?? ""
        }
        detail.isHidden = detail.stringValue.isEmpty
        button.isHidden = button.title.isEmpty
        buttonWidth.constant = ceil(button.intrinsicContentSize.width) + 20
        applyTheme()
        scroll.contentView.scroll(to: .zero)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        desktop.frame = bounds
        guard !scroll.isHidden else { return }
        scroll.frame = bounds
        let size = scroll.contentSize
        let width = max(20, min(field.isHidden ? 340 : 260, size.width - min(32, size.width / 5)))
        stackWidth.constant = width
        heading.preferredMaxLayoutWidth = width
        detail.preferredMaxLayoutWidth = width
        document.setFrameSize(CGSize(width: size.width, height: max(size.height, ceil(stack.fittingSize.height) + 24)))
        document.layoutSubtreeIfNeeded()
    }

    @objc private func submit() { primaryAction?() }
}
