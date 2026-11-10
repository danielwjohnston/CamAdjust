import SwiftUI
import ServiceManagement

/// Observable wrapper around Store preferences.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let changed = Notification.Name("PreferencesChanged")

    @Published var readInterval = Store.shared.readInterval { didSet { Store.shared.readInterval = readInterval } }
    @Published var writeInterval = Store.shared.writeInterval { didSet { Store.shared.writeInterval = writeInterval } }
    @Published var showValues = Store.shared.showValues { didSet { Store.shared.showValues = showValues } }
    @Published var blackAndWhiteIcon = Store.shared.blackAndWhiteIcon {
        didSet { Store.shared.blackAndWhiteIcon = blackAndWhiteIcon; notify() }
    }
    @Published var hideMenuBarIcon = Store.shared.hideMenuBarIcon {
        didSet { Store.shared.hideMenuBarIcon = hideMenuBarIcon; notify() }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}

// MARK: Panel

struct PanelView: View {
    @ObservedObject var manager: CameraManager

    var body: some View {
        VStack(spacing: 0) {
            if let model = manager.selected {
                HStack {
                    Picker("Webcam", selection: Binding(get: { manager.selected?.id ?? "" },
                                                        set: { manager.selectedID = $0 })) {
                        ForEach(manager.cameras) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                    Text(model.formatText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding([.horizontal, .top])
                CameraPanel(model: model, manager: manager).id(model.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "web.camera").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No UVC cameras found").font(.headline)
                    Text("Connect a USB webcam. It will appear here automatically.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 600)
    }
}

struct CameraPanel: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var manager: CameraManager
    @ObservedObject private var prefs = Preferences.shared

    private func states(_ group: ControlGroup) -> [ControlState] {
        model.states.filter { $0.spec.group == group }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $manager.tab) {
                ForEach(availableTabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            Group {
                switch availableTabs.contains(manager.tab) ? manager.tab : .basic {
                case .basic: controls(.basic)
                case .advanced: controls(.advanced, extra: AnyView(ledRow))
                case .panTilt: controls(.panTilt, extra: AnyView(motorPad))
                case .profiles: ProfilesView(model: model, manager: manager)
                case .preferences: PreferencesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack {
                Button("Reset to Default") { model.resetToDefault() }
                Spacer()
                Button {
                    model.refresh()
                } label: { Label("Read from Webcam", systemImage: "arrow.clockwise") }
            }
            .padding([.horizontal, .bottom])
        }
    }

    private var availableTabs: [PanelTab] {
        PanelTab.allCases.filter {
            $0 != .panTilt || !states(.panTilt).isEmpty || model.camera.supportsMotorPanTilt
        }
    }

    @ViewBuilder
    private func controls(_ group: ControlGroup, extra: AnyView? = nil) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(states(group), id: \.spec.key) { state in
                    ControlRow(model: model, state: state, showValue: prefs.showValues)
                }
                if let extra { extra }
                if states(group).isEmpty && extra == nil {
                    Text("This webcam has no \(group.rawValue.lowercased()) controls.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var ledRow: some View {
        if model.camera.supportsLED {
            Picker("LED", selection: Binding(get: { model.ledMode }, set: { model.setLED($0) })) {
                ForEach(LEDMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var motorPad: some View {
        if model.camera.supportsMotorPanTilt {
            VStack(spacing: 6) {
                Text("Motor").font(.headline)
                Button { model.camera.panTiltStep(.up) } label: { Image(systemName: "chevron.up") }
                HStack(spacing: 6) {
                    Button { model.camera.panTiltStep(.left) } label: { Image(systemName: "chevron.left") }
                    Button("Reset") { model.camera.panTiltStep(.reset) }
                    Button { model.camera.panTiltStep(.right) } label: { Image(systemName: "chevron.right") }
                }
                Button { model.camera.panTiltStep(.down) } label: { Image(systemName: "chevron.down") }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: One control

private let controlIcons: [String: (String, String)] = [
    "brightness": ("sun.min", "sun.max.fill"),
    "contrast": ("circle.lefthalf.filled", "circle.lefthalf.striped.horizontal"),
    "hue": ("paintpalette", "paintpalette.fill"),
    "saturation": ("drop", "drop.fill"),
    "sharpness": ("aqi.low", "aqi.high"),
    "gamma": ("chart.line.flattrend.xyaxis", "chart.line.uptrend.xyaxis"),
    "whiteBalance": ("flame", "snowflake"),
    "whiteBalanceU": ("circle", "circle.fill"),
    "whiteBalanceV": ("circle", "circle.fill"),
    "backlight": ("person", "person.fill.viewfinder"),
    "gain": ("speaker.wave.1", "speaker.wave.3"),
    "exposure": ("timer", "timer.circle.fill"),
    "iris": ("camera.aperture", "circle.dashed"),
    "focus": ("mountain.2", "flower"),
    "zoom": ("minus.magnifyingglass", "plus.magnifyingglass"),
    "pan": ("arrow.left", "arrow.right"),
    "tilt": ("arrow.down", "arrow.up"),
]

struct ControlRow: View {
    @ObservedObject var model: CameraModel
    let state: ControlState
    let showValue: Bool

    private var key: String { state.spec.key }
    private var value: Int { model.values[key] ?? state.cur }
    private var automatic: Bool { model.isAutomatic(state.spec) }

    var body: some View {
        switch state.spec.kind {
        case .toggle:
            Toggle(state.spec.title, isOn: Binding(get: { value != 0 }, set: { model.set(key, $0 ? 1 : 0) }))
        case .choice:
            Picker(state.spec.title, selection: Binding(get: { value }, set: { model.set(key, $0) })) {
                ForEach(state.choices, id: \.value) { Text($0.title).tag($0.value) }
            }
        case .relative:
            HStack {
                Text(state.spec.title)
                Spacer()
                Button { model.camera.stepRelative(key, direction: -1) } label: { Image(systemName: "minus") }
                Button { model.camera.stepRelative(key, direction: 1) } label: { Image(systemName: "plus") }
            }
        case .slider:
            slider
        }
    }

    private var slider: some View {
        let icons = controlIcons[key] ?? ("minus", "plus")
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.spec.title)
                if automatic { Text("Auto").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if showValue {
                    TextField("", value: Binding(get: { value }, set: { commit($0) }),
                              format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 6) {
                Button { commit(value - state.res) } label: { Image(systemName: icons.0).frame(width: 18) }
                    .buttonStyle(.borderless)
                Slider(value: Binding(get: { Double(value) }, set: { commit(Int($0.rounded())) }),
                       in: Double(state.min)...Double(state.max))
                Button { commit(value + state.res) } label: { Image(systemName: icons.1).frame(width: 18) }
                    .buttonStyle(.borderless)
            }
        }
        .disabled(automatic)
        .opacity(automatic ? 0.6 : 1)
    }

    /// Clamps to the range and snaps to the camera's step size.
    private func commit(_ raw: Int) {
        let clamped = Swift.min(Swift.max(raw, state.min), state.max)
        let snapped = state.min + ((clamped - state.min) / state.res) * state.res
        if snapped != value { model.set(key, snapped) }
    }
}

// MARK: Profiles

final class ProfilesState: ObservableObject {
    @Published var names: [String] = []
    @Published var selection: String?
    @Published var newName = ""
    @Published var showingSave = false
    @Published var confirmDelete = false
    @Published var startup: String = ""
    @Published var schedules: [Schedule] = []
    @Published var newTime = Date()
    @Published var newScheduleProfile = Store.cameraDefaultProfile
}

struct ProfilesView: View {
    @ObservedObject var model: CameraModel
    let manager: CameraManager
    @StateObject private var vm = ProfilesState()

    private var allNames: [String] { [Store.cameraDefaultProfile] + vm.names }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Profiles for \(model.name)") {
                    VStack(alignment: .leading) {
                        List(allNames, id: \.self, selection: $vm.selection) { Text($0) }
                            .frame(height: 140)
                        HStack {
                            Button("Apply") { if let s = vm.selection { model.applyProfile(s) } }
                                .disabled(vm.selection == nil)
                            Button("Save New Profile…") { vm.newName = ""; vm.showingSave = true }
                            Button("Update Profile") {
                                if let s = vm.selection { Store.shared.saveProfile(s, values: model.settingValues,
                                                                               for: model.modelID) }
                            }
                            .disabled(vm.selection == nil || vm.selection == Store.cameraDefaultProfile)
                            Button("Delete…", role: .destructive) { vm.confirmDelete = true }
                                .disabled(vm.selection == nil || vm.selection == Store.cameraDefaultProfile)
                        }
                        Text("Image quality may still change with lighting, even with saved settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Startup") {
                    Picker("Load at start and when connected", selection: $vm.startup) {
                        Text("None").tag("")
                        ForEach(allNames, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: vm.startup) { value in
                        Store.shared.setStartupProfile(value.isEmpty ? nil : value, for: model.modelID)
                    }
                }

                GroupBox("Schedule") {
                    VStack(alignment: .leading) {
                        ForEach(vm.schedules.filter { $0.modelID == model.modelID }) { schedule in
                            HStack {
                                Toggle("", isOn: Binding(get: { schedule.enabled }, set: { on in
                                    updateSchedules { list in
                                        if let i = list.firstIndex(where: { $0.id == schedule.id }) {
                                            list[i].enabled = on
                                        }
                                    }
                                })).labelsHidden()
                                Text(schedule.timeText).monospacedDigit()
                                Text("Apply “\(schedule.profile)”")
                                Spacer()
                                Button(role: .destructive) {
                                    updateSchedules { $0.removeAll { $0.id == schedule.id } }
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            DatePicker("", selection: $vm.newTime, displayedComponents: .hourAndMinute).labelsHidden()
                            Picker("", selection: $vm.newScheduleProfile) {
                                ForEach(allNames, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            Button("Add Schedule") { addSchedule() }
                        }
                        Text("Applies the profile to \(model.name) at this time every day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $vm.showingSave) { saveSheet }
        .alert("Delete Profile", isPresented: $vm.confirmDelete) {
            Button("Delete", role: .destructive) {
                if let s = vm.selection { Store.shared.deleteProfile(s, for: model.modelID) }
                vm.selection = nil
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Settings “\(vm.selection ?? "")” will be deleted.")
        }
    }

    private var saveSheet: some View {
        let trimmed = vm.newName.trimmingCharacters(in: .whitespaces)
        let conflict = allNames.contains(trimmed)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Save New Profile").font(.headline)
            TextField("Profile Name", text: $vm.newName).frame(width: 260)
            if conflict {
                Text("Profile “\(trimmed)” already exists. Please use another name.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { vm.showingSave = false }
                Button("Save") {
                    Store.shared.saveProfile(trimmed, values: model.settingValues, for: model.modelID)
                    vm.showingSave = false
                    reload()
                    vm.selection = trimmed
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || conflict)
            }
        }
        .padding()
    }

    private func reload() {
        vm.names = Store.shared.profileNames(for: model.modelID)
        vm.startup = Store.shared.startupProfile(for: model.modelID) ?? ""
        vm.schedules = Store.shared.schedules
    }

    private func updateSchedules(_ change: (inout [Schedule]) -> Void) {
        var list = Store.shared.schedules
        change(&list)
        Store.shared.schedules = list
        vm.schedules = list
    }

    private func addSchedule() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: vm.newTime)
        let schedule = Schedule(modelID: model.modelID, cameraName: model.name, profile: vm.newScheduleProfile,
                                hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        updateSchedules { $0.append(schedule) }
    }
}

// MARK: Preferences

struct PreferencesView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Read auto settings from webcam", selection: $prefs.readInterval) {
                    ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
                }
                Text("While auto exposure, auto white balance or auto focus is on, keeps those sliders in step "
                     + "with what the camera is doing.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Write every setting to webcam", selection: $prefs.writeInterval) {
                    ForEach(UpdateInterval.allCases) { Text($0.title).tag($0) }
                }
                Text("Some video apps reset the webcam. This writes your settings back at the chosen interval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show values", isOn: $prefs.showValues)
                Toggle("Use black and white menu bar icon", isOn: $prefs.blackAndWhiteIcon)
                Toggle("Hide menu bar icon", isOn: $prefs.hideMenuBarIcon)
                if prefs.hideMenuBarIcon {
                    Text("Open Webcam Settings again from Finder or Spotlight to show this panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Launch Webcam Settings at login", isOn: $prefs.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}
