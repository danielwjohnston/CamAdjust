# Compatibility notes

CamAdjust aims to cover everything Webcam Settings 3.0 by Mactaris does, so
that people who relied on it can switch. This page lists the behavior
CamAdjust matches and the camera-protocol facts it depends on. CamAdjust
contains no code or assets from Webcam Settings.

## Controls

Standard USB Video Class (UVC 1.1/1.5) controls:

**Processing unit:** Backlight Compensation (0x01), Brightness (0x02),
Contrast (0x03), Gain (0x04), Power Line Frequency (0x05: Disabled / 50 Hz /
60 Hz / Auto), Hue (0x06), Saturation (0x07), Sharpness (0x08), Gamma
(0x09), White Balance Temperature (0x0A) and its Auto switch (0x0B), White
Balance Component U/V (0x0C) and its Auto switch (0x0D), Hue Auto (0x10).

**Camera terminal:** Auto-Exposure Mode (0x02: Manual / Auto / Shutter
Priority / Aperture Priority), Exposure Time Absolute (0x04), Focus Absolute
(0x06), Focus Auto (0x08), Iris Absolute (0x09), Iris Relative (0x0A), Zoom
Absolute (0x0B), Pan/Tilt Absolute (0x0D), Pan/Tilt Relative (0x0E).

Requests go to the camera's VideoControl interface through the IOKit USB
interface user client, without opening the interface, so they work while
macOS's UVC driver uses the camera. If a camera reports it is not
responding, CamAdjust wakes the device and retries once.

## Vendor-specific behavior

- **Logitech LED** (vendor 0x046D), Auto / On / Off, sent as 3 / 1 / 0:
  - Family A (PIDs 0x802–0x80A, 0x80D, 0x80F, 0x817, 0x824, 0x8B5,
    0x8C1–0x8CE and 0x990–0x9C2 subsets): extension unit 13, selector 1,
    3 bytes.
  - Family B (0x80C, 0x819–0x81D, 0x821, 0x825, 0x826, 0x82C, 0x82D, 0x837,
    0x841, 0x843, 0x85C, 0x85E): extension unit 7, 8 or 11 depending on
    model, selector 9, payload `01 <mode> 01 …` of 3, 5 or 10 bytes.
- **Logitech motorized pan/tilt:** extension unit 9, selector 1 (relative
  pan/tilt pulse) and selector 2 with value 3 (reset). The Orbit (0x837)
  uses UVC Pan/Tilt Relative pulses instead.
- **Exposure "knob" cameras** use a 1–15 setting mapped to exposure values
  1, 2, 5, 9, 19, 39, 78, 156, 312, 625, 1250, 2500, 5000, 10000, 20000:
  Microsoft LifeCam (0x045E: 0x75D, 0x76D, 0x76E, 0x76F, 0x772, 0x779),
  Creative (0x041E: 0x4080, 0x4086), HP (0x03F0: 0x8E07) and 0x19FF:0x0218.
- **LifeCam Studio zoom** is stepped up one unit at a time to the target.

## App behavior

- Menu bar app with a colour or black-and-white icon. The icon can be
  hidden, and opening the app again shows the panel.
- Control panel with a camera selector, Basic / Advanced / Pan-Tilt
  sections, the current video format and FPS, and Reset to Default.
- Profiles per camera model: Camera Default, Save New, Update, Delete, with
  a name-conflict check. A startup profile is applied at launch.
- Daily schedules that apply a profile to a camera at a set time.
- "Read auto settings from webcam" interval (Disabled / 0.5 / 1 / 2 / 3 s)
  to follow exposure, gain, white balance and focus while auto modes are on.
- "Write every setting to webcam" interval for apps that reset the camera.
- Timers pause on sleep and resume after wake; USB hot-plug refreshes the
  camera list.
- Launch at Login, show numeric values.

Not reproduced: noise reduction, which Webcam Settings offered only for
Apple's built-in cameras through CoreMediaIO controls that current macOS no
longer provides; licensing, purchase and update checks.
