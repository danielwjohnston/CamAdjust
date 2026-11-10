import Cocoa
import ServiceManagement

// Menu bar (agent) app: lists UVC cameras and opens a settings window for each.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cameras: [UVCCamera] = []
    private var panels: [String: ControlPanelController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Webcam Settings")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // Rediscover cameras; apply saved profiles only to cameras that just appeared.
    private func refreshCameras() {
        let found = UVCCamera.discover()
        let newlyFound = found.filter { camera in !cameras.contains { $0.name == camera.name } }
        cameras = found
        Profiles.applyIfEnabled(to: newlyFound)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshCameras()
        menu.removeAllItems()

        if cameras.isEmpty {
            let none = NSMenuItem(title: "No UVC cameras found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (index, camera) in cameras.enumerated() {
            let item = NSMenuItem(title: "\(camera.name) Settings...",
                                  action: #selector(openPanel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let startup = NSMenuItem(title: "Apply Saved Profiles at Startup", action: #selector(toggleLoadAtStart), keyEquivalent: "")
        startup.target = self
        startup.state = Profiles.loadAtStart ? .on : .off
        menu.addItem(startup)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openPanel(_ sender: NSMenuItem) {
        guard cameras.indices.contains(sender.tag) else { return }
        let camera = cameras[sender.tag]
        panels[camera.name]?.close()
        let controller = ControlPanelController(camera: camera)
        panels[camera.name] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login change failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLoadAtStart() {
        Profiles.loadAtStart.toggle()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
