// Rex's window chrome metrics and normalized split geometry are adapted from
// acoyfellow/rexweb, © 2026 Jordan Coeyman. See Notices/rexweb-LICENSE.
import CoreGraphics
import Foundation

public struct PanePlacement: Equatable {
    public let rect: CGRect
    public let floating: Bool

    public static func locate(block: String, in session: [String: Any]) -> Self? {
        activeWindow(in: session).flatMap { locate(block: block, inWindow: $0) }
    }

    public static func activeWindow(in session: [String: Any]) -> [String: Any]? {
        guard let id = session["active_window_id"] as? String,
            let windows = session["windows"] as? [[String: Any]]
        else { return nil }
        return windows.first { $0["window_id"] as? String == id }
    }

    public static func locate(block: String, inWindow window: [String: Any]) -> Self? {
        if let zoom = window["zoomed_block_id"] as? String, !zoom.isEmpty {
            return zoom == block ? Self(rect: CGRect(x: 0, y: 0, width: 1, height: 1), floating: false) : nil
        }
        let layers = (window["layers"] as? [[String: Any]] ?? []).filter { $0["state"] as? String != "minimized" }
        for (index, layer) in layers.enumerated() {
            guard let rect = find(block, in: layer["layout"] as? [String: Any]) else { continue }
            let floating = layer["kind"] as? String != "tiled"
            // session.view lists layers back to front. Only a layer above this one can cover it.
            if layers.dropFirst(index + 1).contains(where: { other in
                other["kind"] as? String != "tiled" && normalized(other["bounds"])?.intersects(rect) == true
            }) {
                return nil
            }
            return Self(rect: rect, floating: floating)
        }
        return nil
    }

    private static func find(_ block: String, in node: [String: Any]?) -> CGRect? {
        guard let node else { return nil }
        if node["block_id"] as? String == block { return normalized(node["rect"]) }
        guard let split = node["split"] as? [String: Any] else { return nil }
        return find(block, in: split["before"] as? [String: Any]) ?? find(block, in: split["after"] as? [String: Any])
    }

    private static func normalized(_ value: Any?) -> CGRect? {
        guard let v = value as? [Double], v.count == 4, v.allSatisfy(\.isFinite),
            v[2] > 0, v[3] > 0
        else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}

public struct PaneChrome {
    public var top, left, right, bottom, gap, header, radius, floatHeader, floatTop, floatLeft, floatRight: CGFloat

    public init(preference value: (String) -> Any?) {
        let compact = value("paneDensity") as? String == "compact"
        let edge: CGFloat = compact ? 0 : 8
        top = compact ? 41 : 46
        left = edge
        right = edge
        bottom = edge
        gap = compact ? 2 : 8
        radius = compact ? 0 : 10
        let showHeaders =
            value("paneHeaderVisibility") as? String
            ?? ((value("showsPaneHeaders") as? Bool ?? true) ? "always" : "never")
        header = showHeaders == "always" ? (compact ? 35 : 36) : 0
        floatHeader = showHeaders == "always" ? 36 : 0
        floatTop = top - edge
        floatLeft = 0
        floatRight = 0
        if value("tabStyle") as? String == "vertical" {
            top = edge
            floatTop = 38
            if value("sidebarCollapsed") as? Bool != true {
                let width = value("sidebarWidth") as? Double ?? 0
                if value("sidebarPosition") as? String == "right" {
                    right = width
                    floatRight = width
                } else {
                    left = width
                    floatLeft = width
                    floatTop = 0
                }
            }
        } else if let toolbar = value("toolbarBehavior") as? String, toolbar != "alwaysShow" {
            top = edge
            floatTop = 0
        }
    }

    public func body(_ pane: PanePlacement, in window: CGRect) -> CGRect {
        let area: CGRect
        if pane.floating {
            area = CGRect(
                x: window.minX + floatLeft, y: window.minY + floatTop,
                width: window.width - floatLeft - floatRight, height: window.height - floatTop)
        } else {
            area = CGRect(
                x: window.minX + left, y: window.minY + top,
                width: window.width - left - right, height: window.height - top - bottom)
        }
        let f = pane.rect
        var card = CGRect(
            x: area.minX + f.minX * area.width, y: area.minY + f.minY * area.height,
            width: f.width * area.width, height: f.height * area.height)
        if pane.floating {
            card = card.insetBy(dx: 2, dy: 2)
        } else {
            if f.minX > 0.001 {
                card.origin.x += gap / 2
                card.size.width -= gap / 2
            }
            if f.minY > 0.001 {
                card.origin.y += gap / 2
                card.size.height -= gap / 2
            }
            if f.maxX < 0.999 { card.size.width -= gap / 2 }
            if f.maxY < 0.999 { card.size.height -= gap / 2 }
        }
        let inset = pane.floating ? floatHeader : header
        let body = CGRect(x: card.minX, y: card.minY + inset, width: card.width, height: max(0, card.height - inset))
            .intersection(window)
        guard !body.isNull else { return .null }
        let x = ceil(body.minX)
        let y = ceil(body.minY)
        return CGRect(x: x, y: y, width: max(0, floor(body.maxX) - x), height: max(0, floor(body.maxY) - y))
    }
}
