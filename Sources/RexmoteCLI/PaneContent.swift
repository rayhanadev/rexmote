import AppKit

/// Colors come from the same light or dark terminal theme as the surrounding Rex split.
struct RexPalette {
    var background = NSColor.windowBackgroundColor
    var foreground = NSColor.labelColor
    var accent = NSColor.controlAccentColor

    private static let bundled: [String: [String: Any]] = {
        guard
            let url = RexCommand.localApp?.bundleURL?.appendingPathComponent(
                "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"),
            let data = try? Data(contentsOf: url),
            let themes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var result: [String: [String: Any]] = [:]
        for theme in themes {
            if let id = theme["id"] as? String { result[id] = theme["source"] as? [String: Any] }
        }
        return result
    }()

    @MainActor static func current(_ appearance: NSAppearance) -> RexPalette {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let id = PaneTracker.preference(dark ? "darkThemeID" : "lightThemeID") as? String else {
            return RexPalette()
        }
        var source = bundled[id]
        if source == nil, let data = PaneTracker.preference("customThemes") as? Data,
            let custom = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            source = custom.first { $0["id"] as? String == id }?["palette"] as? [String: Any]
        }
        func color(_ name: String, fallback: NSColor) -> NSColor {
            if let string = source?[name] as? String, string.count == 7, string.first == "#",
                let hex = UInt32(string.dropFirst(), radix: 16)
            {
                return NSColor(
                    srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
            }
            if let rgb = source?[name] as? [String: Any], let r = rgb["red"] as? CGFloat,
                let g = rgb["green"] as? CGFloat, let b = rgb["blue"] as? CGFloat
            {
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            return fallback
        }
        return RexPalette(
            background: color("background", fallback: .windowBackgroundColor),
            foreground: color("foreground", fallback: .labelColor),
            accent: color("cursor", fallback: .controlAccentColor))
    }
}

final class PaneContent: NSView {
    enum Screen: Equatable {
        case desktop
        case credential(host: String, prompt: String)
        case status(title: String, detail: String, action: String?)
    }

    let desktop = DesktopView()
    let password = NSSecureTextField()
    var primaryAction: (() -> Void)?
    private let form = NSView()
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private var screen: Screen?
    private var palette = RexPalette()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(desktop)
        addSubview(form)
        for view in [heading, detail, password, button] { form.addSubview(view) }
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 5
        password.font = .systemFont(ofSize: 14)
        password.isBezeled = false
        password.drawsBackground = false
        password.focusRingType = .none
        password.placeholderString = "Password"
        password.setAccessibilityLabel("SSH credential")
        password.target = self
        password.action = #selector(submit)
        button.target = self
        button.action = #selector(submit)
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        applyTheme()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        palette = RexPalette.current(effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = palette.background.cgColor
            heading.textColor = palette.foreground
            detail.textColor = palette.foreground.withAlphaComponent(0.75)
            password.textColor = palette.foreground
            password.placeholderAttributedString = NSAttributedString(
                string: password.placeholderString ?? password.placeholderAttributedString?.string ?? "Password",
                attributes: [.foregroundColor: palette.foreground.withAlphaComponent(0.6)])
            button.attributedTitle = NSAttributedString(
                string: button.title, attributes: [.foregroundColor: palette.background, .font: button.font!])
            button.layer?.backgroundColor = palette.accent.cgColor
        }
        needsDisplay = true
    }

    func show(_ next: Screen) {
        guard next != screen else { return }
        screen = next
        desktop.isHidden = next != .desktop
        form.isHidden = next == .desktop
        switch next {
        case .desktop: return
        case .credential(let host, let prompt):
            heading.stringValue = "Sign in to " + host
            if prompt.localizedCaseInsensitiveContains("passphrase") {
                password.placeholderString = "SSH key passphrase"
                detail.stringValue = ""
            } else if prompt.localizedCaseInsensitiveContains("password") {
                password.placeholderString = "Password"
                detail.stringValue = ""
            } else {
                password.placeholderString = "Response"
                detail.stringValue = prompt
            }
            password.setAccessibilityLabel(password.placeholderString)
            password.isHidden = false
            button.title = "Sign In"
        case .status(let title, let message, let action):
            heading.stringValue = title
            detail.stringValue = message
            password.isHidden = true
            button.title = action ?? ""
        }
        button.isHidden = button.title.isEmpty
        detail.isHidden = detail.stringValue.isEmpty
        applyTheme()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        desktop.frame = bounds
        guard !form.isHidden else { return }
        let width = min(320, max(1, bounds.width - min(40, bounds.width * 0.12)))
        var y: CGFloat = 0
        if !button.isHidden {
            button.frame = CGRect(
                x: 0, y: y, width: min(width, ceil(button.intrinsicContentSize.width) + 22), height: 29)
            y += 43
        }
        if !password.isHidden {
            password.frame = CGRect(x: 9, y: y + 6, width: max(1, width - 18), height: 19)
            y += 46
        }
        if !detail.isHidden {
            let size = detail.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 100)) ?? .zero
            let height = max(18, min(90, ceil(size.height)))
            detail.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height + 8
        }
        heading.frame = CGRect(x: 0, y: y, width: width, height: 25)
        y += 25
        form.frame =
            CGRect(x: (bounds.width - width) / 2, y: max(0, (bounds.height - y) / 2), width: width, height: y).integral
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !password.isHiddenOrHasHiddenAncestor else { return }
        let rect = convert(password.frame, from: form).insetBy(dx: -8, dy: -6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        palette.foreground.withAlphaComponent(0.07).setFill()
        path.fill()
        palette.foreground.withAlphaComponent(0.25).setStroke()
        path.stroke()
    }

    @objc private func submit() { primaryAction?() }
}
