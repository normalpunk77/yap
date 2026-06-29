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

    private static func snapshot(of item: NSPasteboardItem) -> [Representation]? {
        let representations = item.types.compactMap { type -> Representation? in
            if let data = item.data(forType: type) {
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
