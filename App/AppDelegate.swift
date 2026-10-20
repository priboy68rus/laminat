import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    /// Launched without a file (or re-activated with no windows): show the Open panel, like Preview.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }
}

enum MainMenu {
    static func make() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let main = NSMenu()

        main.addSubmenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
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

        main.addSubmenu("File", [
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recentItem,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])

        main.addSubmenu("Edit", [
            item("Copy", #selector(GridViewController.copy(_:)), "c"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Filter…", #selector(GridViewController.focusFilter(_:)), "f"),
        ])

        main.addSubmenu("View", [
            item("Data", #selector(DocumentViewController.showData(_:)), "1"),
            item("SQL", #selector(DocumentViewController.showSQL(_:)), "2"),
            item("Statistics", #selector(DocumentViewController.showStats(_:)), "3"),
            .separator(),
            item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))),
            item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        main.addSubmenu("Query", [
            item("Run", #selector(DocumentViewController.runQuery(_:)), "\r"),
            item("Stop", #selector(DocumentViewController.stopQuery(_:)), "."),
            .separator(),
            item("Insert Template…", #selector(DocumentViewController.showTemplates(_:)), "t"),
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
