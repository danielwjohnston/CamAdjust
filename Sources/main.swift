import Cocoa
import SwiftUI

// Menu bar (agent) app. The status item menu applies profiles and opens the
// control panel; the panel holds every control, profiles, schedules and
// preferences.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let manager = CameraManager()
    private var statusItem: NSStatusItem?
    private var panel: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start()
        installStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: Preferences.changed, object: nil)
        if !Store.shared.welcomeShown {
            Store.shared.welcomeShown = true
            showPanel()
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the panel; this is
    /// the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let item = statusItem else { return }
        item.isVisible = !Store.shared.hideMenuBarIcon
        let symbol = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "CamAdjust")
        if Store.shared.blackAndWhiteIcon {
            symbol?.isTemplate = true
            item.button?.image = symbol
        } else {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemTeal])
            item.button?.image = symbol?.withSymbolConfiguration(config)
        }
    }

    @objc private func preferencesChanged() {
        updateStatusItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let panelVisible = panel?.isVisible == true
        let toggle = NSMenuItem(title: panelVisible ? "Hide CamAdjust Panel" : "Show CamAdjust Panel",
                                action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        if manager.cameras.isEmpty {
            let none = NSMenuItem(title: "No UVC cameras found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for model in manager.cameras {
            let cameraItem = NSMenuItem(title: model.name, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let open = NSMenuItem(title: "Settings…", action: #selector(openCamera(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = model.id
            sub.addItem(open)
            sub.addItem(.separator())
            let header = NSMenuItem(title: "Apply Profile", action: nil, keyEquivalent: "")
            header.isEnabled = false
            sub.addItem(header)
            for name in [Store.cameraDefaultProfile] + Store.shared.profileNames(for: model.modelID) {
                let p = NSMenuItem(title: name, action: #selector(applyProfile(_:)), keyEquivalent: "")
                p.target = self
                p.representedObject = [model.id, name]
                p.indentationLevel = 1
                sub.addItem(p)
            }
            if model.camera.supportsLED {
                sub.addItem(.separator())
                let ledHeader = NSMenuItem(title: "LED", action: nil, keyEquivalent: "")
                ledHeader.isEnabled = false
                sub.addItem(ledHeader)
                for mode in LEDMode.allCases {
                    let l = NSMenuItem(title: mode.title, action: #selector(setLED(_:)), keyEquivalent: "")
                    l.target = self
                    l.representedObject = [model.id, mode.rawValue]
                    l.indentationLevel = 1
                    l.state = model.ledMode == mode ? .on : .off
                    sub.addItem(l)
                }
            }
            cameraItem.submenu = sub
            menu.addItem(cameraItem)
        }

        menu.addItem(.separator())
        let prefs = Preferences.shared
        addToggle(menu, "Launch CamAdjust at Login", prefs.launchAtLogin, #selector(toggleLaunchAtLogin))
        addToggle(menu, "Use Black and White Menu Bar Icon", prefs.blackAndWhiteIcon, #selector(toggleBWIcon))
        addToggle(menu, "Hide Menu Bar Icon", prefs.hideMenuBarIcon, #selector(toggleHideIcon))
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About CamAdjust", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit CamAdjust", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func togglePanel() {
        if panel?.isVisible == true { panel?.orderOut(nil) } else { showPanel() }
    }

    @objc private func openCamera(_ sender: NSMenuItem) {
        manager.selectedID = sender.representedObject as? String
        showPanel()
    }

    @objc private func applyProfile(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String],
              let model = manager.cameras.first(where: { $0.id == info[0] }) else { return }
        model.applyProfile(info[1])
    }

    @objc private func setLED(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let id = info[0] as? String,
              let raw = info[1] as? Int, let mode = LEDMode(rawValue: raw),
              let model = manager.cameras.first(where: { $0.id == id }) else { return }
        model.setLED(mode)
    }

    @objc private func toggleLaunchAtLogin() { Preferences.shared.launchAtLogin.toggle() }
    @objc private func toggleBWIcon() { Preferences.shared.blackAndWhiteIcon.toggle() }
    @objc private func toggleHideIcon() {
        Preferences.shared.hideMenuBarIcon.toggle()
        if Preferences.shared.hideMenuBarIcon { showPanel() }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Adjusts USB Video Class webcam settings."),
        ])
    }

    private func showPanel() {
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "CamAdjust"
            window.contentView = NSHostingView(rootView: PanelView(manager: manager))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("CamAdjustPanel")
            panel = window
        }
        manager.selected?.refresh()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
