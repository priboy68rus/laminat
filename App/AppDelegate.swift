import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    /// Sparkle: checks the GitHub appcast daily (SUFeedURL / SUScheduledCheckInterval in Info.plist).
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(updater: updaterController)
    }

    /// Developer override for testing updates against a local appcast:
    /// `defaults write com.priboy68rus.laminat LaminatFeedURL http://127.0.0.1:8765/appcast.xml`
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "LaminatFeedURL")
    }

    /// Launched without a file (or re-activated with no windows): show the Open panel, like Preview.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    /// File → New Query (⌘N): a query tab over all open files.
    @objc func newQuery(_ sender: Any?) {
        QueryDocument.open()
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/priboy68rus/laminat#readme")!)
    }

    /// ⌘T with no window open: same as Open.
    @objc func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }
}

/// Main menu laid out like native macOS apps (Finder, Numbers, Xcode): standard items, titles and
/// shortcuts, plus View → Data / SQL / Statistics and a Query menu.
enum MainMenu {
    static func make(updater: SPUStandardUpdaterController) -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        let checkForUpdates = item("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
        checkForUpdates.target = updater

        main.addSubmenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            checkForUpdates,
            .separator(),
            servicesItem,
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        // Lets NSDocumentController find and fill this menu, as it does for the one in a nib.
        recent.setValue("NSRecentDocumentsMenu", forKey: "menuName")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent

        // File → Export To ▸, as in Numbers and Pages. The item's tag picks the format in the save panel.
        let exportMenu = NSMenu(title: "Export To")
        for (index, format) in TableSession.ExportFormat.allCases.enumerated() {
            let exportItem = item("\(format.rawValue)…", #selector(GridViewController.exportData(_:)))
            exportItem.tag = index
            exportMenu.addItem(exportItem)
        }
        let exportItem = NSMenuItem(title: "Export To", action: nil, keyEquivalent: "")
        exportItem.submenu = exportMenu

        main.addSubmenu("File", [
            // ⌘T like Finder and Terminal: pick a file and open it as a new tab.
            item("New Query", #selector(AppDelegate.newQuery(_:)), "n"),
            item("New Tab…", #selector(NSResponder.newWindowForTab(_:)), "t"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            exportItem,
        ])

        let find = NSMenu(title: "Find")
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ] {
            let findItem = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
            findItem.tag = action.rawValue
            find.addItem(findItem)
        }
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find

        main.addSubmenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            findItem,
        ])

        main.addSubmenu("View", [
            item("Data", #selector(DocumentViewController.showData(_:)), "1"),
            item("Statistics", #selector(DocumentViewController.showStats(_:)), "2"),
            .separator(),
            item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))),
            item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        // SQL editor commands; the shortcuts are VS Code's.
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        main.addSubmenu("Editor", [
            item("Show Completions", #selector(SQLTextView.showCompletions(_:)), " ", .control),
            .separator(),
            item("Toggle Comment", #selector(SQLTextView.toggleComment(_:)), "/"),
            item("Indent", #selector(SQLTextView.indentLines(_:)), "]"),
            item("Outdent", #selector(SQLTextView.outdentLines(_:)), "["),
            .separator(),
            item("Move Line Up", #selector(SQLTextView.moveLineUp(_:)), up, .option),
            item("Move Line Down", #selector(SQLTextView.moveLineDown(_:)), down, .option),
            item("Copy Line Up", #selector(SQLTextView.copyLineUp(_:)), up, [.option, .shift]),
            item("Copy Line Down", #selector(SQLTextView.copyLineDown(_:)), down, [.option, .shift]),
            item("Delete Line", #selector(SQLTextView.deleteLine(_:)), "k", [.command, .shift]),
        ])

        main.addSubmenu("Query", [
            item("Run", #selector(SQLViewController.runQuery(_:)), "\r"),
            item("Stop", #selector(SQLViewController.stopQuery(_:)), "."),
            .separator(),
            item("Insert Template…", #selector(SQLViewController.showTemplates(_:)), "t", [.command, .shift]),
        ])

        let window = main.addSubmenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]),
            item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", .control),
            item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window

        let help = main.addSubmenu("Help", [
            item("\(appName) Help", #selector(AppDelegate.showHelp(_:)), "?"),
        ])
        NSApp.helpMenu = help  // adds the system menu search field

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

private extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return submenu
    }
}
