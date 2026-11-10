# Webcam Settings (Apple Silicon rewrite)

A menu bar app that adjusts USB Video Class (UVC) webcam settings:
brightness, contrast, hue, saturation, sharpness, gamma, white balance,
backlight compensation, gain, exposure, focus and zoom. It also saves
per-camera profiles and can re-apply them at startup.

This is a fresh Swift implementation built as a universal binary
(arm64 + x86_64). It was not taken from the original binary, which is
x86_64 only and ships without source.

## Requirements

- Mac with Apple Silicon (or Intel; the build is universal)
- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build

    chmod +x build.sh
    ./build.sh

The app is written to `build/WebcamSettings.app`. Move it to
`/Applications` and open it. A camera icon appears in the menu bar.

Check the architectures with:

    lipo -info build/WebcamSettings.app/Contents/MacOS/WebcamSettings

Expected output: `Architectures in the fat file ... are: x86_64 arm64`

## Use

1. Click the camera icon in the menu bar.
2. Choose "<camera name> Settings..." to open the slider window.
3. Adjust sliders. Changes apply immediately.
4. "Save Profile" stores the current values for that camera.
5. "Apply Saved Profiles at Startup" re-applies saved values when a
   matching camera is found.
6. "Launch at Login" registers the app as a login item.

## How it talks to the camera

UVC control requests go through each camera's VideoControl interface
(class 14, subclass 1) using the IOKit `IOUSBInterfaceInterface` user
client and `ControlRequest` on the default pipe. This does not need
exclusive access, so it works while macOS's own UVC driver owns the
camera. (`IOUSBHostDevice` from IOUSBHost.framework was tried first; it
requires an exclusive open, which always fails for an active camera.)

Tested on macOS 27 with a Razer Kiyo and the Apple Thunderbolt Display
FaceTime HD camera: controls are discovered, and writes read back
correctly.

Notes:

- Unsupported controls. Only controls that answer GET_MIN and GET_MAX
  with a non-empty range are shown.
- The Razer Kiyo's brightness has been seen to change between sessions
  on its own; "Apply Saved Profiles at Startup" re-applies saved values.

## Not included compared with the original

- Pan and tilt controls
- Power line frequency (anti-flicker) and auto-exposure mode switching
- CoreMediaIO-based controls
- Black-and-white menu bar icon option

## Distribution

The build is ad-hoc signed and not notarized, so it runs on the Mac that
built it. To share it, sign with a Developer ID certificate and notarize
with `notarytool`. Mac App Store distribution would need the App Sandbox
and USB entitlements, which are not set up here.
