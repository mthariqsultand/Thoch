import SwiftUI

@main
struct ThochApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Tidak ada jendela utama. Semua UI hidup di panel notch.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchController = NotchWindowController()
        notchController?.show()
        setupStatusItem()

        // Posisi ulang kalau resolusi / monitor berubah
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        notchController?.reposition()
    }

    // Ikon kecil di menu bar, buat Quit (karena app tidak punya ikon Dock)
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "Thoch")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Thoch",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
