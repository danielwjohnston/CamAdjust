import Cocoa

// One window per camera with a slider for each supported UVC control.
final class ControlPanelController: NSWindowController {
    private let camera: UVCCamera
    private let states: [UVCControlState]
    private var sliders: [String: NSSlider] = [:]
    private var valueLabels: [String: NSTextField] = [:]
    private var specs: [String: UVCControlSpec] = [:]

    init(camera: UVCCamera) {
        self.camera = camera
        self.states = camera.controlStates()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "\(camera.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
    }

    required init?(coder: NSCoder) {
        fatalError("ControlPanelController is not created from a nib")
    }

    private func buildContent(in window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        if states.isEmpty {
            root.addArrangedSubview(NSTextField(labelWithString: "This camera does not expose adjustable UVC controls."))
        } else {
            var rows: [[NSView]] = []
            for state in states {
                let key = state.spec.key
                specs[key] = state.spec

                let label = NSTextField(labelWithString: state.spec.title)
                let slider = NSSlider(value: Double(state.cur),
                                      minValue: Double(state.min),
                                      maxValue: Double(state.max),
                                      target: self,
                                      action: #selector(sliderChanged(_:)))
                slider.identifier = NSUserInterfaceItemIdentifier(key)
                slider.isContinuous = true
                slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

                let value = NSTextField(labelWithString: String(state.cur))
                value.alignment = .right
                value.widthAnchor.constraint(equalToConstant: 60).isActive = true

                sliders[key] = slider
                valueLabels[key] = value
                rows.append([label, slider, value])
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 10
            grid.columnSpacing = 12
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .fill
            grid.column(at: 2).xPlacement = .trailing
            root.addArrangedSubview(grid)
        }

        let saveButton = NSButton(title: "Save Profile", target: self, action: #selector(saveProfile))
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults))
        let buttons = NSStackView(views: [saveButton, resetButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        root.addArrangedSubview(buttons)

        window.contentView = root
        window.setContentSize(root.fittingSize)
        window.center()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue, let spec = specs[key] else { return }
        let value = sender.integerValue
        valueLabels[key]?.stringValue = String(value)
        camera.setValue(spec, value)
    }

    @objc private func saveProfile() {
        var values: [String: Int] = [:]
        for (key, slider) in sliders {
            values[key] = slider.integerValue
        }
        Profiles.save(values, for: camera.name)

        let alert = NSAlert()
        alert.messageText = "Profile saved"
        alert.informativeText = "Settings for \(camera.name) were saved."
        alert.runModal()
    }

    @objc private func resetDefaults() {
        for state in states {
            guard let slider = sliders[state.spec.key] else { continue }
            slider.integerValue = state.def
            valueLabels[state.spec.key]?.stringValue = String(state.def)
            camera.setValue(state.spec, state.def)
        }
    }
}
