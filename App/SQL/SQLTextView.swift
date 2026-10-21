import AppKit

/// The SQL editor's text view. Dropping data files from Finder hands them to `onDropFiles` (which adds
/// them as tables, possibly loading in the background) and inserts the table names it reports back at
/// the drop point.
final class SQLTextView: NSTextView {
    var onDropFiles: ((_ urls: [URL], _ insertNames: @escaping (String) -> Void) -> Void)?

    static func makeScrollable() -> (NSScrollView, SQLTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return (scroll, textView)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TablesSidebar.dataFileURLs(from: sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)  // moves the insertion point under the mouse
        return TablesSidebar.dataFileURLs(from: sender.draggingPasteboard).isEmpty ? operation : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = TablesSidebar.dataFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        guard let onDropFiles else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        window?.makeFirstResponder(self)
        onDropFiles(urls) { [weak self] text in
            guard let self else { return }
            let location = min(index, (string as NSString).length)
            let range = NSRange(location: location, length: 0)
            if shouldChangeText(in: range, replacementString: text) {
                replaceCharacters(in: range, with: text)
                didChangeText()
                setSelectedRange(NSRange(location: location + (text as NSString).length, length: 0))
            }
        }
        return true
    }
}
