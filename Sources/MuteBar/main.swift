import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum AppState {
    case noMeeting
    case live
    case muted

    var symbol: String {
        switch self {
        case .noMeeting: return "mic"
        case .live: return "mic.fill"
        case .muted: return "mic.slash.fill"
        }
    }

    var title: String {
        switch self {
        case .noMeeting: return "No active meeting"
        case .live: return "Mic on"
        case .muted: return "Muted"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var state: AppState = .noMeeting
    private var browserConnected = false
    // fd -> latest state per browser connection; any in-meeting browser wins
    private var connStates: [Int32: (inMeeting: Bool, muted: Bool)] = [:]

    private var hotkey: Hotkey {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "hotkeyCode") != nil else { return .default }
            return Hotkey(
                keyCode: UInt32(defaults.integer(forKey: "hotkeyCode")),
                modifiers: UInt32(defaults.integer(forKey: "hotkeyMods"))
            )
        }
        set {
            UserDefaults.standard.set(Int(newValue.keyCode), forKey: "hotkeyCode")
            UserDefaults.standard.set(Int(newValue.modifiers), forKey: "hotkeyMods")
        }
    }

    /// On by default — it is the reason to reach for AirPods support at all.
    /// Unticking it stops the `log stream` child process the watcher runs.
    private var stemPressEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "stemPressEnabled") != nil else { return true }
            return defaults.bool(forKey: "stemPressEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "stemPressEnabled") }
    }

    private var stemStatus: StemPressWatcher.Status = .stopped
    private var gestureStatus: MuteGestureHandler.Status = .stopped

    /// One press can reach us twice — once through the supported handler and once
    /// through the log — so collapse anything arriving close together.
    private var lastGestureAt: Date?
    private static let gestureDedupInterval: TimeInterval = 0.5

    private var recorder: RecorderPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.image = statusImage()
        statusItem = item
        rebuildMenu()

        HotKeyCenter.action = { [weak self] in self?.toggleMute() }
        applyHotkey()

        SocketServer.shared.onMessage = { [weak self] fd, json in
            DispatchQueue.main.async {
                guard let self, let type = json["type"] as? String else { return }
                if type == "state" {
                    let inMeeting = json["inMeeting"] as? Bool ?? false
                    let muted = json["muted"] as? Bool ?? false
                    self.connStates[fd] = (inMeeting, muted)
                    self.recomputeState()
                }
            }
        }
        SocketServer.shared.onClientChange = { [weak self] count in
            DispatchQueue.main.async {
                guard let self else { return }
                self.browserConnected = count > 0
                // drop states from closed connections
                let live = Set(SocketServer.shared.clientFDs)
                self.connStates = self.connStates.filter { live.contains($0.key) }
                self.recomputeState()
                self.rebuildMenu()
            }
        }
        StemPressWatcher.shared.onPress = { [weak self] in self?.handleStemGesture() }
        StemPressWatcher.shared.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.stemStatus = status
            self.rebuildMenu()
        }

        MuteGestureHandler.shared.onGesture = { [weak self] _ in self?.handleStemGesture() }
        MuteGestureHandler.shared.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.gestureStatus = status
            // Seed it with where the meeting already is, since the first mirror
            // would otherwise wait for the next state change.
            if status == .claimed {
                MuteGestureHandler.shared.reflect(muted: self.state == .muted)
            }
            self.rebuildMenu()
        }

        DispatchQueue.global(qos: .utility).async {
            NativeHostRegistration.register()
        }
        SocketServer.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MuteGestureHandler.shared.stop()
        StemPressWatcher.shared.stop()
        SocketServer.shared.stop()
        return .terminateNow
    }

    private func recomputeState() {
        let inMeeting = connStates.values.filter { $0.inMeeting }
        if let s = inMeeting.last {
            setState(s.muted ? .muted : .live)
        } else {
            setState(.noMeeting)
        }
        syncStemWatcher()
    }

    /// Both triggers only run during a meeting: outside one there is nothing to
    /// toggle, a stem press should fall through to its normal play/pause, and the
    /// microphone has no business being open.
    private func syncStemWatcher() {
        if stemPressEnabled && state != .noMeeting {
            MuteGestureHandler.shared.start()
            StemPressWatcher.shared.start()
        } else {
            MuteGestureHandler.shared.stop()
            StemPressWatcher.shared.stop()
        }
    }

    /// Entry point for both trigger paths. The supported handler and the log can
    /// each report the same press, so the first one through wins.
    private func handleStemGesture() {
        let now = Date()
        if let last = lastGestureAt, now.timeIntervalSince(last) < Self.gestureDedupInterval {
            return
        }
        lastGestureAt = now
        toggleMute()
    }

    // MARK: - Actions

    private func toggleMute() {
        SocketServer.shared.broadcast(["type": "toggle"])
    }

    private func applyHotkey() {
        if !HotKeyCenter.register(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers) {
            NSLog("MuteBar: hotkey registration failed for \(hotkey.label)")
        }
    }

    @objc private func changeHotkey() {
        HotKeyCenter.unregister() // don't trigger the old shortcut while recording
        NSApp.activate(ignoringOtherApps: true)
        let panel = RecorderPanel(currentLabel: hotkey.label)
        panel.onDone = { [weak self, weak panel] result in
            guard let self else { return }
            if let result {
                if HotKeyCenter.register(keyCode: result.keyCode, modifiers: result.modifiers) {
                    self.hotkey = result
                } else {
                    // registration failed (system conflict) — keep the old shortcut
                    let alert = NSAlert()
                    alert.messageText = "\"\(result.label)\" is not available"
                    alert.informativeText = "It conflicts with an existing system shortcut. Please pick another."
                    alert.runModal()
                    self.applyHotkey()
                }
            } else {
                self.applyHotkey()
            }
            self.rebuildMenu()
            self.recorder = nil
        }
        recorder = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleStemPress(_ sender: NSMenuItem) {
        stemPressEnabled.toggle()
        syncStemWatcher()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MuteBar: login item toggle failed: \(error)")
        }
        rebuildMenu()
    }

    // MARK: - UI state

    private func setState(_ newState: AppState) {
        guard newState != state else { return }
        state = newState
        statusItem.button?.image = statusImage()
        // Meet owns the truth; keep macOS's own idea of our mute state in step
        // with it so the accessory signals the gesture as having taken effect.
        MuteGestureHandler.shared.reflect(muted: newState == .muted)
        rebuildMenu()
    }

    /// Template monochrome icon: blends with the menubar and adapts to
    /// light/dark mode automatically. Sized relative to the system status
    /// bar thickness (not a fixed point size) so it stays correct on both
    /// standard and tall/notched menu bars; the cell clamps it if needed.
    private func statusImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(
            pointSize: NSStatusBar.system.thickness * 0.66, weight: .medium
        )
        let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// Which trigger path is carrying the gesture, and why the system banner may
    /// still be appearing. `nil` once the supported handler has it — that is the
    /// good case and the checkmark already says the feature is on.
    private var stemStatusNote: String? {
        switch gestureStatus {
        case .claimed:
            return nil
        case .microphoneDenied:
            return "Stem press: works, but allow the mic to hide the system alert"
        case .failed, .unsupported, .stopped:
            break
        }

        switch stemStatus {
        case .watching: return "Stem press: using system log"
        case .needsAdmin: return "Stem press: needs an admin account"
        case .stopped: return "Stem press: waiting for a meeting"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let statusLine = NSMenuItem(title: state.title, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let connLine = NSMenuItem(
            title: browserConnected ? "Browser: connected" : "Browser: not connected",
            action: nil, keyEquivalent: ""
        )
        connLine.isEnabled = false
        menu.addItem(connLine)

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Toggle mute (\(hotkey.label))", action: #selector(toggleMuteMenu), keyEquivalent: "")
        menu.addItem(toggle)

        let shortcutLine = NSMenuItem(
            title: "Mute shortcut: \(hotkey.label)", action: nil, keyEquivalent: ""
        )
        shortcutLine.isEnabled = false
        menu.addItem(shortcutLine)
        menu.addItem(NSMenuItem(
            title: "Change Shortcut…", action: #selector(changeHotkey), keyEquivalent: ""
        ))

        let stemItem = NSMenuItem(
            title: "Mute with AirPods stem press",
            action: #selector(toggleStemPress(_:)), keyEquivalent: ""
        )
        stemItem.state = stemPressEnabled ? .on : .off
        menu.addItem(stemItem)

        if stemPressEnabled, let note = stemStatusNote {
            let stemLine = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            stemLine.isEnabled = false
            menu.addItem(stemLine)
        }

        let loginItem = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: ""
        )
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MuteBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleMuteMenu() { toggleMute() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
