# Analysis of the original Webcam Settings 3.0

Source: the Mac App Store build installed at `/Applications/Webcam Settings.app`
(bundle `com.mactaris.Webcam-Settings`, version 3.0 / 0301, x86_64 only,
built with Xcode 11 against the macOS 10.10 SDK, minimum macOS 10.7).

Tools: [rea](https://rea.tools) 6.8.0 driving Ghidra 12.1.4 (`rea analyze`,
`rea decompile-all`, `rea decode-interface-builder`), plus rizin for data
tables. 620 functions were decompiled. Only facts about behavior and the USB
protocol were taken from the analysis; no code, images, or nib files from the
original are used in this project.

## Architecture of the original

| Class | Role |
|---|---|
| `WebcamSettings` | App delegate: status item, panel, profiles, schedules, timers, sleep/wake, USB and AVFoundation hot-plug |
| `AVCamera` | One camera: UVC control requests via the IOKit USB interface user client, CoreMediaIO fallback for non-USB (built-in) cameras, vendor quirks |
| `UVCValueViewController` | One control row: title, low/high icons, slider, −/+ buttons, value field, auto switch |
| `PopWindow`, `PopViewController`, `StatusItemView` | First-run "is here!" popover pointing at the menu bar icon |
| `PeriodicDelaySlider` | Slider that rate-limits its action messages while dragging |

## Transport

- Finds the VideoControl interface for a camera by location ID / vendor /
  product, then sends `ControlRequest` on pipe 0 through
  `IOUSBInterfaceInterface` without opening the interface.
- On `kIOReturnNotResponding` it opens the device to wake it, closes it, and
  retries the request once.
- Cameras with Apple's vendor ID (0x106B) and no USB path use CoreMediaIO
  controls instead (this is where Noise Reduction comes from).

## Controls

Processing unit: Backlight Compensation (0x01), Brightness (0x02), Contrast
(0x03), Gain (0x04), Power Line Frequency (0x05: Disabled / 50 Hz / 60 Hz /
Auto), Hue (0x06), Saturation (0x07), Sharpness (0x08), Gamma (0x09), White
Balance Temperature (0x0A) and its Auto switch (0x0B), White Balance U/V
(component).

Camera terminal: Auto-Exposure Mode (0x02: Manual / Auto / Shutter Priority /
Aperture Priority), Exposure Time Absolute (0x04), Focus Absolute (0x06) and
Focus Auto (0x08), Iris Relative (0x0A, "Aperture" −/+), Zoom Absolute (0x0B),
Pan/Tilt Absolute (0x0D), Pan/Tilt Relative (0x0E).

CoreMediaIO only: Noise Reduction.

## Vendor quirks

- **Logitech LED (vendor 0x046D)**, options Auto / On / Off (sent as 3 / 1 / 0):
  - Family A (PIDs 0x802–0x80A, 0x80D, 0x80F, 0x817, 0x824, 0x8B5, 0x8C1–0x8CE
    subset, 0x990–0x9C2 subset): SET_CUR, extension unit 13, selector 1, 3 bytes.
  - Family B (0x80C, 0x819–0x81D, 0x821, 0x825, 0x826, 0x82C, 0x82D, 0x837,
    0x841, 0x843, 0x85C, 0x85E): SET_CUR to extension unit 7, 8 or 11 by PID,
    selector 9, payload `01 <mode> 01 …` of 3, 5 or 10 bytes. 0x82D and 0x837
    first send an extra "on" frame.
- **Logitech motorized pan/tilt**: extension unit 9, selector 1 (4 bytes,
  relative pan/tilt pulse) and selector 2 value 3 (reset). PID 0x837 (Orbit)
  uses UVC Pan/Tilt Relative pulses instead.
- **Exposure "knob" cameras** map a 1–15 knob to exposure values
  1, 2, 5, 9, 19, 39, 78, 156, 312, 625, 1250, 2500, 5000, 10000, 20000:
  Microsoft 0x045E PIDs 0x75D, 0x76D, 0x76E, 0x76F, 0x772, 0x779; Creative
  0x041E 0x4080 and 0x4086; HP 0x03F0 0x8E07; 0x19FF 0x0218.
- **LifeCam Studio zoom** is stepped up one unit at a time to the target.

## App behavior

- Menu bar (agent) app with a colour or black-and-white icon; the icon can be
  hidden, and relaunching the app shows the panel.
- Control panel: camera selector, Basic / Advanced / Pan-Tilt tabs, current
  video format and FPS, Reset to Default.
- Profiles per camera model: "Camera Default", Save New Profile, Update
  Profile, Delete Profile, name-conflict check. "Load at Start" applies a
  profile when the app starts and when the camera is plugged in.
- Schedules: apply a chosen profile to a camera at a set time every day.
- Read interval ("Read auto settings from webcam"): Disabled / 0.5 / 1 / 2 /
  3 s. Refreshes Exposure, Gain, White Balance Temperature and Focus while
  their auto modes are on.
- Write interval ("Write every settings to webcam"): Disabled / 0.5 / 1 / 2 /
  3 s. Rewrites all settings, because apps such as Skype reset cameras.
- Sleep/wake: timers stop on sleep and restart 2 s after wake.
- Hot-plug: USB and AVFoundation connect/disconnect notifications refresh the
  camera list.
- Launch at Login; show numeric values; first-run popover; licence/purchase
  and update check (not reproduced: not applicable to a self-built app).
