import Foundation

/// Follows the unified log for AirPods stem presses (the mute gesture).
///
/// macOS routes the mute gesture in-process to whichever app is capturing from
/// the accessory, via `AVAudioApplication.setInputMuteStateChangeHandler`. For a
/// browser call that app is the browser, and neither Chrome nor Safari registers
/// a handler — hence the system's "Cannot Control Mic with AirPods" banner. An
/// app that isn't capturing cannot observe the gesture through any supported API.
///
/// `bluetoothd` does log every press, so we follow that instead. This is an
/// undocumented log message that Apple can rename in any release: if presses stop
/// arriving, suspect the marker before suspecting the hardware.
final class StemPressWatcher {
    enum Status {
        /// Not running — either disabled, or no meeting is active.
        case stopped
        /// `log stream` is attached and presses will be reported.
        case watching
        /// `log stream` refuses non-admin accounts; the trigger cannot work.
        case needsAdmin
    }

    static let shared = StemPressWatcher()

    /// bluetoothd emits this for every stem press once the accessory reports mute
    /// control (AACP control cmd 0x27). Verified on macOS 27.0.1 with AirPods Pro.
    private static let marker = "Received Software Mute"

    /// One gesture occasionally produces more than one log line; collapse those.
    /// Kept short so a deliberate mute-then-unmute still registers as two presses.
    private static let debounceInterval: TimeInterval = 0.4

    private static let firstRestartDelay: TimeInterval = 1
    private static let maxRestartDelay: TimeInterval = 30

    /// Invoked on the main queue for each debounced press.
    var onPress: (() -> Void)?
    /// Invoked on the main queue when `status` changes.
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .stopped

    private let queue = DispatchQueue(label: "mutebar.stem-press")
    private var process: Process?
    private var buffer = ""
    private var lastPressAt: Date?
    private var restartDelay: TimeInterval = StemPressWatcher.firstRestartDelay
    private var restartWork: DispatchWorkItem?
    private var running = false
    private var sawAdminRefusal = false

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.restartDelay = Self.firstRestartDelay
            self.sawAdminRefusal = false
            self.spawn()
        }
    }

    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.restartWork?.cancel()
            self.restartWork = nil
            self.teardown()
            self.setStatus(.stopped)
        }
    }

    // MARK: - Process lifecycle

    private func spawn() {
        buffer = ""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "stream",
            "--style", "ndjson",
            "--predicate", #"process == "bluetoothd" AND eventMessage CONTAINS ""# + Self.marker + #"""#,
        ]

        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async { self?.ingest(text, from: task) }
        }

        // `log stream` rejects standard accounts outright; surface that rather than
        // restarting forever against a condition that will never clear.
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("MuteBar: log stream stderr: %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
            if text.contains("Must be admin") {
                self?.queue.async { self?.sawAdminRefusal = true }
            }
        }

        task.terminationHandler = { [weak self] finished in
            self?.queue.async { self?.handleExit(of: finished) }
        }

        do {
            try task.run()
            process = task
            setStatus(.watching)
        } catch {
            NSLog("MuteBar: could not start log stream: %@", String(describing: error))
            process = nil
            scheduleRestart()
        }
    }

    /// `terminationHandler` can fire for a process we already replaced or stopped;
    /// only the current one may schedule a restart.
    private func handleExit(of finished: Process) {
        guard finished === process else { return }
        teardown()

        guard running else { return }
        if sawAdminRefusal {
            NSLog("MuteBar: stem press needs an admin account — trigger disabled")
            setStatus(.needsAdmin)
            running = false
            return
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(delay * 2, Self.maxRestartDelay)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.restartWork = nil
            self.spawn()
        }
        restartWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardown() {
        if let task = process {
            (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (task.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if task.isRunning { task.terminate() }
        }
        process = nil
    }

    // MARK: - Parsing

    /// The predicate already filters to stem presses, so any line carrying the
    /// marker is one. Matching the substring rather than decoding the NDJSON keeps
    /// this working if Apple changes the envelope around the message.
    private func ingest(_ text: String, from task: Process) {
        guard task === process else { return }

        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if line.contains(Self.marker) { registerPress() }
        }

        // A pathological line with no newline shouldn't grow without bound.
        if buffer.count > 64 * 1024 { buffer = "" }
    }

    private func registerPress() {
        let now = Date()
        if let last = lastPressAt, now.timeIntervalSince(last) < Self.debounceInterval { return }
        lastPressAt = now

        // First press after a restart lands here too; that's intended, the gesture
        // happened regardless of how long the stream had been up.
        DispatchQueue.main.async { [weak self] in self?.onPress?() }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(new) }
    }
}

extension StemPressWatcher.Status: Equatable {}
