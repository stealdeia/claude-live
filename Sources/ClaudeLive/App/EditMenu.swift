import AppKit

/// Gives the app a main menu, so that copy and paste work.
///
/// An `LSUIElement` app has no menu bar, and it is tempting to conclude it needs
/// no menu. It does: `Cmd+V` is not handled by the text field, it is a key
/// equivalent looked up in `NSApp.mainMenu` and then sent down the responder
/// chain. With no main menu there is nothing to look it up in, so the shortcut
/// does nothing — in every text field the app has, silently.
///
/// The menu is never seen. It exists only so the standard editing shortcuts
/// resolve, which is why it carries the editing items and nothing else.
enum EditMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let main = NSMenu()

        // AppKit expects the first item to be the application menu and skips it
        // when matching key equivalents; without it the Edit menu would be
        // treated as the app menu and its shortcuts ignored.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Modifica")

        // nil target: each one travels the responder chain and is handled by
        // whatever text field currently has focus.
        add(to: edit, "Annulla", #selector(UndoManager.undo), "z")
        add(to: edit, "Ripristina", #selector(UndoManager.redo), "Z")
        edit.addItem(.separator())
        add(to: edit, "Taglia", #selector(NSText.cut(_:)), "x")
        add(to: edit, "Copia", #selector(NSText.copy(_:)), "c")
        add(to: edit, "Incolla", #selector(NSText.paste(_:)), "v")
        add(to: edit, "Seleziona tutto", #selector(NSText.selectAll(_:)), "a")

        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private static func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // An uppercase letter means the shortcut carries Shift, which is what
        // distinguishes Redo from Undo.
        if key.first?.isUppercase == true {
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        menu.addItem(item)
    }
}
