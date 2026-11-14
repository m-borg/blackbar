import Cocoa
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static let shared = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    var statusItem: NSStatusItem!
    var isEnabled: Bool = true
    var roundCorners: Bool = true
    var originalWallpapers: [CGDirectDisplayID: URL] = [:]
    var generatedWallpapers: [CGDirectDisplayID: URL] = [:]
    private var wallpaperSlot: [CGDirectDisplayID: Int] = [:]

    // Wallpaper observation state
    private var wallpaperStoreSource: DispatchSourceFileSystemObject?
    private var wallpaperStoreDescriptor: Int32 = -1
    private var wallpaperPollTimer: Timer?
    private var wallpaperDebounceWorkItem: DispatchWorkItem?
    private var isApplyingWallpaper: Bool = false
    private var lastAppliedTime: Date = .distantPast

    private var blackBarDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("blackbar.BlackBar", isDirectory: true)
    }

    func purgeUnusedWallpapers(keeping activeURLs: Set<URL> = []) {
        let dir = blackBarDirectoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("notchless_") {
            if !activeURLs.contains(file) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BlackBar: Launched")
        NSApp.setActivationPolicy(.accessory)

        roundCorners = UserDefaults.standard.object(forKey: "round_corners") as? Bool ?? true

        setupStatusItem()

        // Clean up any stale orphaned wallpaper files from previous runs
        let currentDesktops = Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) })
        purgeUnusedWallpapers(keeping: currentDesktops)

        applyBlackBar(force: true)
        setupWallpaperObserver()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWallpaperObserver()
        restoreOriginalWallpapers()
    }

    // MARK: - Menu Bar Setup

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "BlackBar"
            )
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: "Hide Notch",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        toggleItem.state = isEnabled ? .on : .off
        toggleItem.target = self
        menu.addItem(toggleItem)

        let roundCornersItem = NSMenuItem(
            title: "Round Corners",
            action: #selector(toggleRoundCorners(_:)),
            keyEquivalent: ""
        )
        roundCornersItem.state = roundCorners ? .on : .off
        roundCornersItem.target = self
        menu.addItem(roundCornersItem)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit BlackBar",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        if isEnabled {
            applyBlackBar(force: true)
        } else {
            restoreOriginalWallpapers()
        }
    }

    @objc func toggleRoundCorners(_ sender: NSMenuItem) {
        roundCorners.toggle()
        UserDefaults.standard.set(roundCorners, forKey: "round_corners")
        sender.state = roundCorners ? .on : .off
        if isEnabled {
            applyBlackBar(force: true)
        }
    }

    @objc func screenParametersChanged() {
        if isEnabled {
            applyBlackBar(force: true)
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if isLaunchAtLoginEnabled() {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = isLaunchAtLoginEnabled() ? .on : .off
        } catch {
            NSLog("BlackBar: Launch at login error: \(error)")
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc func quit() {
        stopWallpaperObserver()
        restoreOriginalWallpapers()
        NSApp.terminate(nil)
    }

    // MARK: - Resource-Optimized Wallpaper Observation

    func setupWallpaperObserver() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        // 1. Observe Spaces / Desktops switches
        wsCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // 2. Battery saver: Pause polling when screen or system sleeps
        wsCenter.addObserver(
            self,
            selector: #selector(powerSleepOccurred),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(powerSleepOccurred),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(powerWakeOccurred),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(powerWakeOccurred),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // 3. Kernel event watcher (kqueue) on wallpaper store directory
        // Uses 0% CPU while idle; only wakes up when wallpaper configuration is written
        setupWallpaperStoreKqueue()

        // 4. Low-power fallback timer (every 10s with 5s tolerance to coalesce wakeups)
        startWallpaperPollTimer()
    }

    private func setupWallpaperStoreKqueue() {
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.apple.wallpaper/Store")

        guard let storePath = storeURL?.path, FileManager.default.fileExists(atPath: storePath) else { return }

        wallpaperStoreDescriptor = open(storePath, O_EVTONLY)
        guard wallpaperStoreDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: wallpaperStoreDescriptor,
            eventMask: [.write, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedCheck()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.wallpaperStoreDescriptor, fd >= 0 {
                close(fd)
                self?.wallpaperStoreDescriptor = -1
            }
        }
        source.resume()
        wallpaperStoreSource = source
    }

    private func startWallpaperPollTimer() {
        guard wallpaperPollTimer == nil else { return }
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkForExternalWallpaperChange()
        }
        // Allow timer coalescing to save CPU/battery ticks
        timer.tolerance = 5.0
        RunLoop.main.add(timer, forMode: .common)
        wallpaperPollTimer = timer
    }

    private func stopWallpaperPollTimer() {
        wallpaperPollTimer?.invalidate()
        wallpaperPollTimer = nil
    }

    func stopWallpaperObserver() {
        wallpaperDebounceWorkItem?.cancel()
        wallpaperDebounceWorkItem = nil

        stopWallpaperPollTimer()

        wallpaperStoreSource?.cancel()
        wallpaperStoreSource = nil

        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc func powerSleepOccurred() {
        stopWallpaperPollTimer()
    }

    @objc func powerWakeOccurred() {
        startWallpaperPollTimer()
        checkForExternalWallpaperChange()
    }

    @objc func activeSpaceChanged() {
        scheduleDebouncedCheck()
    }

    private func scheduleDebouncedCheck() {
        guard isEnabled, !isApplyingWallpaper else { return }
        wallpaperDebounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.checkForExternalWallpaperChange()
        }
        wallpaperDebounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func checkForExternalWallpaperChange() {
        guard isEnabled, !isApplyingWallpaper else { return }
        guard Date().timeIntervalSince(lastAppliedTime) > 2.5 else { return }

        var changed = false
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0 else { continue }
            let screenID = displayID(for: screen)
            guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }

            let isOurCurrentGen = (generatedWallpapers[screenID] != nil && currentURL == generatedWallpapers[screenID])
            let isOurCurrentOrig = (originalWallpapers[screenID] != nil && currentURL == originalWallpapers[screenID])
            let isGenFilename = currentURL.path.contains("blackbar.BlackBar") || currentURL.lastPathComponent.hasPrefix("notchless_")

            // A truly new wallpaper chosen by the user
            if !isOurCurrentGen && !isOurCurrentOrig && !isGenFilename {
                NSLog("BlackBar: Detected new user wallpaper: \(currentURL.lastPathComponent)")
                changed = true
                break
            }
        }

        if changed {
            applyBlackBar(force: false)
        }
    }

    // MARK: - Wallpaper Notch Hiding

    func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    func applyBlackBar(force: Bool = false) {
        guard !isApplyingWallpaper else { return }
        isApplyingWallpaper = true
        defer {
            isApplyingWallpaper = false
            lastAppliedTime = Date()
        }

        for screen in NSScreen.screens {
            let topInset = screen.safeAreaInsets.top
            guard topInset > 0 else { continue }

            let screenID = displayID(for: screen)
            guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }

            // If already showing our generated wallpaper and not forcing, skip
            if !force, let activeGen = generatedWallpapers[screenID], currentURL == activeGen {
                continue
            }

            let isGenFilename = currentURL.path.contains("blackbar.BlackBar") || currentURL.lastPathComponent.hasPrefix("notchless_")
            if !isGenFilename {
                originalWallpapers[screenID] = currentURL
                UserDefaults.standard.set(currentURL.path, forKey: "original_wallpaper_\(screenID)")
            }

            let sourceURL = originalWallpapers[screenID] ?? {
                if let savedPath = UserDefaults.standard.string(forKey: "original_wallpaper_\(screenID)") {
                    return URL(fileURLWithPath: savedPath)
                }
                return isGenFilename ? nil : currentURL
            }()

            guard let wallpaperSource = sourceURL else { continue }

            do {
                let modifiedURL = try generateNotchlessWallpaper(for: screen, from: wallpaperSource)
                generatedWallpapers[screenID] = modifiedURL

                try NSWorkspace.shared.setDesktopImageURL(modifiedURL, for: screen, options: [:])
                NSLog("BlackBar: Applied notchless wallpaper for screen \(screenID) with source: \(wallpaperSource.lastPathComponent)")

                // Prune any old wallpaper files after a short delay so macOS WallpaperServices finishes loading the image
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    guard let self = self else { return }
                    let active = Set(self.generatedWallpapers.values)
                    self.purgeUnusedWallpapers(keeping: active)
                }
            } catch {
                NSLog("BlackBar: Failed to apply wallpaper for screen \(screenID): \(error)")
            }
        }
    }

    func restoreOriginalWallpapers() {
        for screen in NSScreen.screens {
            let screenID = displayID(for: screen)
            var sourceURL = originalWallpapers[screenID]
            if sourceURL == nil, let savedPath = UserDefaults.standard.string(forKey: "original_wallpaper_\(screenID)") {
                sourceURL = URL(fileURLWithPath: savedPath)
            }

            guard let url = sourceURL else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                NSLog("BlackBar: Restored original wallpaper for screen \(screenID)")
            } catch {
                NSLog("BlackBar: Failed to restore wallpaper: \(error)")
            }
        }
        generatedWallpapers.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.purgeUnusedWallpapers(keeping: [])
        }
    }

    func generateNotchlessWallpaper(for screen: NSScreen, from sourceURL: URL) throws -> URL {
        try autoreleasepool { () -> URL in
            guard let originalImage = NSImage(contentsOf: sourceURL) else {
                throw NSError(
                    domain: "BlackBar",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to load original wallpaper at \(sourceURL.path)"]
                )
            }

            let screenBounds = screen.frame
            let notchHeightPoints = screen.safeAreaInsets.top
            let scale = screen.backingScaleFactor
            let targetPixelWidth = Int(screenBounds.width * scale)
            let targetPixelHeight = Int(screenBounds.height * scale)
            let notchHeightPixels = notchHeightPoints * scale
            let desktopTopY = CGFloat(targetPixelHeight) - notchHeightPixels

            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: targetPixelWidth,
                pixelsHigh: targetPixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw NSError(
                    domain: "BlackBar",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap context."]
                )
            }

            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current = context

            // 1. Fill entire canvas with pure black
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: targetPixelWidth, height: targetPixelHeight).fill()

            // 2. Define wallpaper clipping path
            let path = CGMutablePath()
            let widthF = CGFloat(targetPixelWidth)

            if roundCorners {
                let radius: CGFloat = 18.0 * scale

                // Start bottom-left
                path.move(to: CGPoint(x: 0, y: radius))
                // Bottom-left corner
                path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: radius, y: 0), radius: radius)
                // Bottom edge
                path.addLine(to: CGPoint(x: widthF - radius, y: 0))
                // Bottom-right corner
                path.addArc(tangent1End: CGPoint(x: widthF, y: 0), tangent2End: CGPoint(x: widthF, y: radius), radius: radius)
                // Right edge up to top-right corner below black bar
                path.addLine(to: CGPoint(x: widthF, y: desktopTopY - radius))
                // Top-right corner beneath black bar
                path.addArc(tangent1End: CGPoint(x: widthF, y: desktopTopY), tangent2End: CGPoint(x: widthF - radius, y: desktopTopY), radius: radius)
                // Top edge directly below black bar
                path.addLine(to: CGPoint(x: radius, y: desktopTopY))
                // Top-left corner beneath black bar
                path.addArc(tangent1End: CGPoint(x: 0, y: desktopTopY), tangent2End: CGPoint(x: 0, y: desktopTopY - radius), radius: radius)
                path.closeSubpath()
            } else {
                // Straight rectangular wallpaper area
                path.addRect(CGRect(x: 0, y: 0, width: widthF, height: desktopTopY))
            }

            if let cgContext = context?.cgContext {
                cgContext.addPath(path)
                cgContext.clip()
            }

            // 3. Draw original wallpaper scaled (aspect fill) inside clipped region
            let originalSize = originalImage.size
            let scaleX = widthF / originalSize.width
            let scaleY = CGFloat(targetPixelHeight) / originalSize.height
            let fillScale = max(scaleX, scaleY)
            let drawWidth = originalSize.width * fillScale
            let drawHeight = originalSize.height * fillScale
            let drawX = (widthF - drawWidth) / 2.0
            let drawY = (CGFloat(targetPixelHeight) - drawHeight) / 2.0
            let drawRect = NSRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

            originalImage.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)

            NSGraphicsContext.restoreGraphicsState()

            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw NSError(
                    domain: "BlackBar",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to convert bitmap to PNG."]
                )
            }

            let blackBarDir = blackBarDirectoryURL
            try FileManager.default.createDirectory(at: blackBarDir, withIntermediateDirectories: true)

            let screenID = displayID(for: screen)
            let nextSlot = (wallpaperSlot[screenID] ?? 0) ^ 1
            wallpaperSlot[screenID] = nextSlot
            let destinationURL = blackBarDir.appendingPathComponent("notchless_\(screenID)_\(nextSlot).png")
            try pngData.write(to: destinationURL, options: .atomic)

            return destinationURL
        }
    }
}
