import AppKit

/// Rex ships its interface colors with each built-in theme. Imported themes store their base palette in preferences.
struct RexPalette: Equatable {
    let background, primary, secondary, field, border, accent, onAccent: NSColor

    private static let bundled: [String: [String: Any]] = {
        let app = RexCommand.localApp?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: RexCommand.bundleID)
        guard let url = app?.appendingPathComponent(
            "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"),
            let data = try? Data(contentsOf: url),
            let themes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var result = [String: [String: Any]]()
        for theme in themes {
            if let id = theme["id"] as? String { result[id] = theme["semantic"] as? [String: Any] }
        }
        return result
    }()

    init(semantic: [String: Any] = [:], custom: [String: Any] = [:]) {
        func color(_ value: Any?) -> NSColor? {
            if let hex = value as? String, hex.count == 7, hex.first == "#",
                let rgb = UInt32(hex.dropFirst(), radix: 16)
            {
                return NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat(rgb >> 8 & 255) / 255,
                               blue: CGFloat(rgb & 255) / 255, alpha: 1)
            }
            guard let color = value as? [String: Any], let red = color["red"] as? Double,
                let green = color["green"] as? Double, let blue = color["blue"] as? Double
            else { return nil }
            let alpha = color["alpha"] as? Double ?? 1
            if color["colorSpace"] as? String == "display-p3" {
                return NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
        background = color(semantic["canvas"]) ?? color(custom["background"]) ?? .windowBackgroundColor
        primary = color(semantic["content"]) ?? color(custom["foreground"]) ?? .labelColor
        secondary = color(semantic["contentSecondary"]) ?? primary.withAlphaComponent(0.72)
        field = color(semantic["surface"]) ?? primary.withAlphaComponent(0.06)
        border = color(semantic["stroke"]) ?? primary.withAlphaComponent(0.24)
        accent = color(semantic["accentSolid"]) ?? color(custom["cursor"]) ?? .controlAccentColor
        onAccent = color(semantic["accentOnSolid"]) ?? color(custom["cursorText"]) ?? background
    }

    @MainActor static func current(_ appearance: NSAppearance) -> Self {
        let dark: Bool
        switch PaneTracker.preference("appearance") as? String {
        case "dark": dark = true
        case "light": dark = false
        default: dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        guard let id = PaneTracker.preference(dark ? "darkThemeID" : "lightThemeID") as? String else { return Self() }
        if let tokens = bundled[id] { return Self(semantic: tokens) }
        guard let data = PaneTracker.preference("customThemes") as? Data,
            let themes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let colors = themes.first(where: { $0["id"] as? String == id })?["palette"] as? [String: Any]
        else { return Self() }
        return Self(custom: colors)
    }
}
