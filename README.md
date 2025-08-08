# ADB Explorer for macOS

A native macOS SwiftUI application for browsing, pulling, and pushing files on Android devices connected via [ADB](https://developer.android.com/studio/command-line/adb).  
It acts as a graphical frontend for `adb shell ls`, `adb pull`, and `adb push`, with full drag-and-drop support.

## Features

- **Browse Android filesystem** over USB or TCP/IP ADB.
- **Drag-and-drop**:
  - Drag files/folders from device → Finder to pull.
  - Drop files/folders from Finder → device to push.
- **Directory navigation** with double-click or breadcrumb.
- **Multiple device support**.
- **Configurable ADB path** (defaults to `/opt/homebrew/bin/adb`).
- **Fallbacks** for different `ls` formats in Toybox-based Android shells.

## Requirements

- macOS 13.0 or later.
- `adb` installed and working (`brew install android-platform-tools`).
- USB debugging enabled on the Android device.

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/410-dev/Android-Browser-over-ADB
   cd Android-Browser-over-ADB


## Note
Default directory is /storage/emulated/0.


## Credit
Code, README.md written by GPT-5.
