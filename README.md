# BlackBar

A lightweight, native macOS menu bar utility that hides the MacBook display notch by adding a solid black top bar directly to your wallpaper—inspired by **TopNotch**, built in pure Swift with zero external dependencies.

---

## How It Works

Just like TopNotch, BlackBar operates **purely at the desktop wallpaper level** rather than drawing floating overlay windows or interfering with macOS system UI:

1. Detects built-in displays that have a notch (`safeAreaInsets.top > 0`), while leaving external/non-notched monitors untouched.
2. Reads your active wallpaper and generates a retina-resolution PNG with a pure-black bar matching the exact height of the notch (`safeAreaInsets.top × backingScaleFactor`).
3. Optionally rounds the corners (`18 pt` radius) directly beneath the black bar and at the bottom of the screen for a seamless bezel look.
4. Applies the generated wallpaper automatically across Spaces and restores your original wallpaper whenever you toggle it off or quit.

No Accessibility, Screen Recording, or extra system permissions required.

---

## Features

- **Menu Bar Controls** (`NSStatusItem`, runs cleanly as a menu bar accessory with no Dock icon):
  - **Hide Notch** — Toggle the black bar on/off (immediately restores your original wallpaper when disabled).
  - **Round Corners** — Toggle rounded display corners below the black bar.
  - **Launch at Login** — Native macOS login item support via `SMAppService`.
  - **Quit BlackBar** (`⌘Q`) — Cleanly restores your original wallpaper on exit.
- **Automatic Wallpaper Sync:**
  - Detects when you change wallpapers or switch macOS Spaces using `NSWorkspace` notifications and a zero-idle-CPU `kqueue` file watcher on `~/Library/Application Support/com.apple.wallpaper/Store`.
  - Uses a sleep-aware fallback timer (`10s` interval with `5s` timer coalescing) that pauses while your screen or Mac is asleep.
- **Zero Bloat:**
  - Single-file Swift app (`AppDelegate.swift`) using only `Cocoa` and `ServiceManagement`.
  - Automatically cleans up older generated wallpaper PNGs from `~/Library/Application Support/blackbar.BlackBar/`.

---

## Installation

### Download Release
1. Download `BlackBar-v1.1.zip` from the [Releases](https://github.com/m-borg/black-bar/releases) page.
2. Unzip it and move `BlackBar.app` into `/Applications`.
3. Launch `BlackBar.app` *(if macOS Gatekeeper warns on first launch because the app is ad-hoc signed, right-click `BlackBar.app` → **Open**, or allow it under **System Settings → Privacy & Security**)*.

### Build from Source
1. Clone the repository:
   ```bash
   git clone https://github.com/m-borg/black-bar.git
   ```
2. Open `BlackBar.xcodeproj` in Xcode and build/run the **BlackBar** target (`⌘R`).
