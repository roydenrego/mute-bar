import AVFoundation

/// Claims the AirPods mute gesture through the supported API.
///
/// `AVAudioApplication.setInputMuteStateChangeHandler` is how macOS delivers the
/// gesture, and returning `true` from it is the only documented way to suppress
/// the system's "Cannot Control Mic with AirPods" banner. Registering alone is
/// not enough: the handler is only invoked while the process has an active record
/// session, which is why this opens an input tap and throws every buffer away.
///
/// No audio is kept. The tap exists so macOS counts us as a recording app; the
/// buffers are discarded in the callback and never copied, written or sent.
///
/// If the handler does fire, it is strictly better than `StemPressWatcher`: it is
/// public API rather than a log message Apple can rename. Treat the watcher as the
/// fallback for when this is unavailable — denied microphone permission, or a
/// macOS build that routes the gesture elsewhere.
final class MuteGestureHandler {
    enum Status {
        /// Not running — no meeting, or deliberately stopped.
        case stopped
        /// Record session is live and the handler is registered.
        case claimed
        /// Microphone access was denied; the banner cannot be suppressed.
        case microphoneDenied
        /// Below macOS 14 there is no gesture API at all.
        case unsupported
        /// Something else went wrong starting the engine or registering.
        case failed
    }

    static let shared = MuteGestureHandler()

    /// Invoked on the main queue when the gesture arrives through the supported
    /// API. The flag is what macOS thinks the new mute state should be; we treat
    /// it as a toggle request because Meet owns the real state.
    var onGesture: ((Bool) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .stopped

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var handlerRegistered = false

    /// Setting `isInputMuted` re-enters the handler. That echo is our own write
    /// coming back, not a press, so it must not be forwarded as a gesture.
    /// Touched from both the audio callback thread and main, hence the lock.
    private var echoLock = NSLock()
    private var expectingEcho = false

    func start() {
        guard status != .claimed else { return }

        // Don't prompt for the microphone on a system that could never use it.
        guard #available(macOS 14.0, *) else {
            setStatus(.unsupported)
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    NSLog("MuteBar: microphone denied — gesture banner cannot be suppressed")
                    self.setStatus(.microphoneDenied)
                    return
                }
                self.beginSession()
            }
        }
    }

    func stop() {
        guard status != .stopped else { return }

        if handlerRegistered {
            if #available(macOS 14.0, *) {
                try? AVAudioApplication.shared.setInputMuteStateChangeHandler(nil)
            }
            handlerRegistered = false
        }
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        setStatus(.stopped)
    }

    // MARK: - Internals

    private func beginSession() {
        do {
            try openRecordSession()
            try registerHandler()
            setStatus(.claimed)
        } catch {
            NSLog("MuteBar: could not claim mute gesture: %@", String(describing: error))
            stop()
            setStatus(.failed)
        }
    }

    /// Opens the default input and discards everything it produces. The format is
    /// taken from the node rather than assumed — an input that reports 0 channels
    /// (device still settling after a route change) would throw on tap install.
    private func openRecordSession() throws {
        guard !tapInstalled else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw NSError(
                domain: "MuteBar", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "input device reported no channels"]
            )
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in
            // Deliberately empty: the buffer is dropped here. Pulling it is the
            // entire point — it is what makes this an active record session.
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func registerHandler() throws {
        guard #available(macOS 14.0, *) else {
            throw NSError(
                domain: "MuteBar", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "mute gesture API requires macOS 14"]
            )
        }
        try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] shouldBeMuted in
            guard let self else { return true }

            self.echoLock.lock()
            let isEcho = self.expectingEcho
            self.expectingEcho = false
            self.echoLock.unlock()

            // true = "handled", which is what suppresses the system banner.
            guard !isEcho else { return true }
            DispatchQueue.main.async { self.onGesture?(shouldBeMuted) }
            return true
        }
        handlerRegistered = true
    }

    /// Mirrors the meeting's real mute state onto `AVAudioApplication`.
    ///
    /// Returning `true` from the handler only says we handled the press; it does
    /// not tell macOS what the state became, and `isInputMuted` is the app's to
    /// set. Left unset it stays `false` forever, so the system believes nothing
    /// was ever muted and signals the gesture as ineffective even though the
    /// banner is suppressed.
    func reflect(muted: Bool) {
        guard #available(macOS 14.0, *), status == .claimed else { return }
        guard AVAudioApplication.shared.isInputMuted != muted else { return }

        echoLock.lock()
        expectingEcho = true
        echoLock.unlock()

        do {
            try AVAudioApplication.shared.setInputMuted(muted)
        } catch {
            echoLock.lock()
            expectingEcho = false
            echoLock.unlock()
            NSLog("MuteBar: could not mirror mute state: %@", String(describing: error))
        }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(new) }
    }
}

extension MuteGestureHandler.Status: Equatable {}
