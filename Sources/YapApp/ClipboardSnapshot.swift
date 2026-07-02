import AppKit

struct ClipboardSnapshot {
    private struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data?
        let string: String?
        let propertyList: Any?

        func write(into item: NSPasteboardItem) {
            if let data {
                item.setData(data, forType: type)
            } else if let string {
                item.setString(string, forType: type)
            } else if let propertyList {
                item.setPropertyList(propertyList, forType: type)
            }
        }
    }

    private let items: [[Representation]]

    init?(pasteboardItems: [NSPasteboardItem]?) {
        guard let pasteboardItems, !pasteboardItems.isEmpty else { return nil }
        let snapshots = pasteboardItems.compactMap(Self.snapshot(of:))
        guard !snapshots.isEmpty else { return nil }
        items = snapshots
    }

    init?(pasteboard: NSPasteboard) {
        self.init(pasteboardItems: pasteboard.pasteboardItems)
    }

    func restoredItems() -> [NSPasteboardItem] {
        items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                representation.write(into: item)
            }
            return item
        }
    }

    /// Reading a representation MATERIALIZES it, and this runs on the main thread at
    /// paste time. Bound the work: skip file promises (they resolve lazily — possibly
    /// off the network — and don't survive a restore anyway) and anything huge, so a
    /// multi-hundred-MB copy sitting on the clipboard can't beachball every dictation.
    private static let maxRepresentationBytes = 10 * 1024 * 1024

    private static func snapshot(of item: NSPasteboardItem) -> [Representation]? {
        let representations = item.types.compactMap { type -> Representation? in
            if type.rawValue.hasPrefix("com.apple.pasteboard.promised") { return nil }
            if let data = item.data(forType: type) {
                guard data.count <= maxRepresentationBytes else { return nil }
                return Representation(type: type, data: data, string: nil, propertyList: nil)
            }
            if let string = item.string(forType: type) {
                return Representation(type: type, data: nil, string: string, propertyList: nil)
            }
            if let propertyList = item.propertyList(forType: type) {
                return Representation(type: type, data: nil, string: nil, propertyList: propertyList)
            }
            return nil
        }
        return representations.isEmpty ? nil : representations
    }
}
