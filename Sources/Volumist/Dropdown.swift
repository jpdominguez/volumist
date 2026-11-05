import AppKit
import SwiftUI

struct DropdownItem {
    let title: String
    var isSelected = false
    var isSeparatorBefore = false
    let action: () -> Void
}

/// A dropdown that opens its menu by itself. A menu closes if the app becomes active while it is
/// open, and a click in this popover can do just that, so the app is activated first.
struct Dropdown: NSViewRepresentable {
    let title: String
    let items: [DropdownItem]
    var color: NSColor = .labelColor
    var accessibilityLabel: String

    func makeNSView(context: Context) -> Control { Control() }

    func updateNSView(_ control: Control, context: Context) {
        control.items = items
        control.setAccessibilityLabel(accessibilityLabel)
        control.configure(title: title, color: color)
    }

    final class Control: NSButton {
        var items: [DropdownItem] = []
        private(set) var activeMenu: NSMenu?
        private var activationObserver: NSObjectProtocol?

        init() {
            super.init(frame: .zero)
            isBordered = false
            imagePosition = .imageTrailing
            image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            setContentHuggingPriority(.required, for: .horizontal)
            lineBreakMode = .byTruncatingTail
        }

        required init?(coder: NSCoder) { fatalError("Not used from a nib") }

        func configure(title: String, color: NSColor) {
            let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
            contentTintColor = color
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { openMenu() }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                if item.isSeparatorBefore { menu.addItem(.separator()) }
                let entry = NSMenuItem(title: item.title, action: #selector(MenuTarget.run), keyEquivalent: "")
                let target = MenuTarget(item.action)
                entry.target = target
                entry.representedObject = target // a menu item doesn't retain its target
                entry.state = item.isSelected ? .on : .off
                menu.addItem(entry)
            }
            return menu
        }

        func openMenu() {
            guard !NSApp.isActive else { return showMenu() }
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.showPendingMenu()
            }
            NSApp.activate(ignoringOtherApps: true)
            // macOS may refuse to activate the app, and the menu must open anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.showPendingMenu() }
        }

        private func showPendingMenu() {
            guard let observer = activationObserver else { return }
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
            // Out of the notification, so that activation finishes before the menu's event loop starts.
            DispatchQueue.main.async { [weak self] in self?.showMenu() }
        }

        private func showMenu() {
            let menu = makeMenu()
            activeMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            activeMenu = nil
        }
    }

    final class MenuTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}
