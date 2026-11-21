import AppKit

/// Transfer the portable representations of each item together, so the receiving app can choose a format.
public enum DesktopClipboard {
    public static let byteLimit = 32 * 1024 * 1024
    private static let itemLimit = 128
    private static let types: [NSPasteboard.PasteboardType] = [
        .string, .URL, .html, .rtf, .png, .init("public.jpeg"), .init("com.compuserve.gif"),
        .init("public.heic"), .pdf, .tiff, .rtfd,
    ]

    @MainActor public static func read(from board: NSPasteboard) -> Data? {
        let change = board.changeCount
        guard let items = board.pasteboardItems, (1...itemLimit).contains(items.count) else { return nil }
        var contents: [[String: Data]] = []
        var remaining = byteLimit
        for item in items {
            let offered = Set(item.types)
            guard !offered.contains(.fileURL) else { return nil }
            var values: [String: Data] = [:]
            for type in types where offered.contains(type) {
                guard let data = item.data(forType: type), data.count <= remaining else { continue }
                values[type.rawValue] = data
                remaining -= data.count
            }
            guard !values.isEmpty else { return nil }
            contents.append(values)
        }
        guard board.changeCount == change,
            let data = try? PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0),
            data.count <= byteLimit
        else { return nil }
        return data
    }

    @MainActor @discardableResult public static func write(_ data: Data, to board: NSPasteboard) -> Bool {
        guard !data.isEmpty, data.count <= byteLimit,
            let items = try? PropertyListDecoder().decode([[String: Data]].self, from: data),
            (1...itemLimit).contains(items.count)
        else { return false }
        var objects: [NSPasteboardItem] = []
        var remaining = byteLimit
        for values in items {
            guard (1...types.count).contains(values.count) else { return false }
            let item = NSPasteboardItem()
            for (name, bytes) in values {
                let type = NSPasteboard.PasteboardType(name)
                guard types.contains(type), bytes.count <= remaining, item.setData(bytes, forType: type) else {
                    return false
                }
                remaining -= bytes.count
            }
            objects.append(item)
        }
        board.prepareForNewContents(with: .currentHostOnly)
        return board.writeObjects(objects)
    }
}
