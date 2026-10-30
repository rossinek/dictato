import AppKit

/// Owns one clipboard write. Restoration must never overwrite a later copy,
/// even when the later clipboard happens to contain the same text.
@MainActor
final class PasteboardTransaction {
    private let pasteboard: NSPasteboard
    private let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
    private let writtenChangeCount: Int
    private var finished = false

    let didWrite: Bool

    var ownsClipboard: Bool {
        !finished && didWrite && pasteboard.changeCount == writtenChangeCount
    }

    init(pasteboard: NSPasteboard, text: String, isTransient: Bool = false) {
        self.pasteboard = pasteboard
        savedItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []

        // Publish actual data, not a promise: clipboard readers are not evidence
        // that the destination editor has finished pasting.
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if isTransient {
            item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        }
        pasteboard.clearContents()
        didWrite = pasteboard.writeObjects([item])
        writtenChangeCount = pasteboard.changeCount
    }

    @discardableResult
    func restoreIfOwned() -> Bool {
        guard ownsClipboard else {
            finished = true
            return false
        }
        finished = true
        // Preserve the existing behavior when there was nothing to restore.
        guard !savedItems.isEmpty else { return false }

        let items = savedItems.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}
