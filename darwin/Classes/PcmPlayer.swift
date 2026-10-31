import AVFoundation
import AudioToolbox

// Asks Dart for up to maxFrames frames. The reply (nil if it wasn't a
// Uint8List) must be passed to the completion on the main thread.
typealias SampleCallback = (
    _ maxFrames: Int, _ completion: @escaping (Data?) -> Void
) -> Void
typealias PlayingCallback = (_ playing: Bool) -> Void

// Plays PCM through an output AUAudioUnit (DefaultOutput on macOS, RemoteIO
// on iOS).
//
// The format is float32 interleaved stereo at the hardware's sample rate.
// The audio unit converts it to whatever the device wants.
//
// The render callback runs on a real-time thread and asks for a few hundred
// frames at a time, too often and too urgently to call Dart each time. It
// plays from a SampleQueue, a double buffer: when it swaps buffers, it wakes
// the main thread through a dispatch source, and the main thread asks Dart to
// fill the free one. At most one getSamples request is outstanding. A late
// reply is still played; until then the render callback plays silence.
//
// Every method is called on the main thread.
//
// On iOS, playback pauses when an interruption begins (a phone call, another
// app taking the audio session) and resumes when it ends if the system says
// it should. It also pauses when the output device goes away (headphones
// unplugged), and when the media services are reset; the next play rebuilds
// the audio unit. Each of these is reported through playingCallback.
final class PcmPlayer {
    // Pending means playback should start as soon as it can: when setup has
    // run, if setPlaying(true) came before it, or when an interruption ends
    private enum PlayState { case paused, playing, pending }

    private let sampleCallback: SampleCallback
    private let playingCallback: PlayingCallback

    // Set by setup
    private var queue: SampleQueue?
    private var signal: DispatchSourceUserDataAdd?
    private var sampleRate: Double = 0

    // Nil before setup, and after the media services were reset
    private var audioUnit: AUAudioUnit?
    private var hardwareRunning = false

    private var playState = PlayState.paused
    private var requestPending = false
    private var gain: Float = 1

    #if os(iOS)
        private var observers: [NSObjectProtocol] = []
    #endif

    init(
        sampleCallback: @escaping SampleCallback,
        playingCallback: @escaping PlayingCallback
    ) {
        self.sampleCallback = sampleCallback
        self.playingCallback = playingCallback
    }

    deinit {
        release()
    }

    var isSetUp: Bool { queue != nil }

    var volume: Float {
        get { gain }
        set {
            guard !newValue.isNaN else {
                return
            }
            gain = min(max(newValue, 0), 1)
            queue?.setGain(gain)
        }
    }

    // If this throws, the player isn't set up and setup can be called again
    func setup() throws -> (frequency: Int, channels: Int) {
        precondition(!isSetUp)

        #if os(iOS)
            try readSessionSampleRate()
        #endif

        let unit = try makeAudioUnit()
        #if os(macOS)
            sampleRate = unit.outputBusses[0].format.sampleRate
        #endif
        if sampleRate <= 0 {
            sampleRate = 48000
        }

        // Each buffer must hold at least one render call, or every call that
        // swaps buffers would also run out
        let capacity = max(
            Int(sampleRate) / 20,
            Int(unit.maximumFramesToRender)
        )
        let queue = SampleQueue(channels: 2, capacity: capacity)
        queue.setGain(gain)

        let signal = DispatchSource.makeUserDataAddSource(queue: .main)
        signal.setEventHandler { [weak self] in
            self?.requestSamples()
        }
        signal.activate()

        do {
            try configure(unit, queue: queue, signal: signal)
        } catch {
            signal.cancel()
            throw error
        }
        self.queue = queue
        self.signal = signal
        audioUnit = unit
        #if os(iOS)
            observeSession()
        #endif
        return (Int(sampleRate), queue.channels)
    }

    // Starts playing if setPlaying(true) came before setup. Called after the
    // reply to setup, so that Dart gets the first sample request, or the
    // refusal, once setup has completed.
    func startIfPending() {
        if playState == .pending {
            setPlaying(true)
        }
    }

    func setPlaying(_ play: Bool) {
        if play {
            if !start() {
                playingCallback(false)
            }
        } else {
            stop()
        }
    }

    func release() {
        stop()
        #if os(iOS)
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
        #endif
        audioUnit?.deallocateRenderResources()
        audioUnit = nil
        signal?.cancel()
        signal = nil
    }

    private func makeAudioUnit() throws -> AUAudioUnit {
        #if os(macOS)
            let subType = kAudioUnitSubType_DefaultOutput
        #else
            let subType = kAudioUnitSubType_RemoteIO
        #endif
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let unit = try AUAudioUnit(componentDescription: description)
        #if os(iOS)
            // When the screen is locked, iOS renders 4096 frames at a time
            unit.maximumFramesToRender = 4096
        #endif
        return unit
    }

    // Sets the format and the render callback, and allocates the unit
    private func configure(
        _ unit: AUAudioUnit,
        queue: SampleQueue,
        signal: DispatchSourceUserDataAdd
    ) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(queue.channels),
                interleaved: true
            )
        else {
            throw NSError(domain: "flutter_pcm", code: 1)
        }
        try unit.inputBusses[0].setFormat(format)

        // Runs on the real-time thread: only touches the queue and the signal,
        // which don't allocate or wait
        let frameSize = queue.frameSize
        unit.outputProvider = {
            _, _, frameCount, _, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count > 0, let data = buffers[0].mData else {
                return kAudio_ParamError
            }
            let frames = min(
                Int(frameCount),
                Int(buffers[0].mDataByteSize) / frameSize
            )
            if queue.render(
                into: data.assumingMemoryBound(to: Float.self),
                frames: frames
            ) {
                signal.add(data: 1)
            }
            return noErr
        }
        try unit.allocateRenderResources()
    }

    // Starts the hardware, building the unit first if the media services were
    // reset. Returns false and leaves playback paused if that fails.
    private func start() -> Bool {
        guard let queue, let signal else {
            // setup starts playing
            playState = .pending
            return true
        }
        playState = .playing
        if hardwareRunning {
            return true
        }
        do {
            #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if audioUnit == nil {
                let unit = try makeAudioUnit()
                try configure(unit, queue: queue, signal: signal)
                audioUnit = unit
            }
            // Ask for samples first; the reply should come shortly after the
            // hardware starts
            requestSamples()
            try audioUnit!.startHardware()
            hardwareRunning = true
            return true
        } catch {
            NSLog("flutter_pcm: can't start playback: %@", "\(error)")
            stop()
            return false
        }
    }

    // Stops the hardware. Pass .pending to resume when an interruption ends.
    // On iOS, pausing also deactivates the session, so that other apps' audio
    // can resume; during an interruption the system has already done that.
    private func stop(into state: PlayState = .paused) {
        playState = state
        if hardwareRunning {
            audioUnit?.stopHardware()
            hardwareRunning = false
        }
        #if os(iOS)
            if state == .paused {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        #endif
    }

    private func requestSamples() {
        guard playState == .playing, !requestPending, let queue,
            queue.needsSamples
        else {
            return
        }
        requestPending = true
        sampleCallback(queue.capacity) { [weak self] data in
            self?.onSamples(data)
        }
    }

    // A reply that arrives while paused is kept and played on resume
    private func onSamples(_ data: Data?) {
        guard let queue else {
            return
        }
        let frames = data?.withUnsafeBytes { queue.fill(from: $0) } ?? 0
        if frames > 0 {
            requestPending = false
            return
        }
        // An empty or failed reply: ask again after a while
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            [weak self] in
            self?.requestPending = false
            self?.requestSamples()
        }
    }

    #if os(iOS)
        // Sets the session's category and reads its sample rate. An inactive
        // session may report a rate the route doesn't run at, so activate it
        // briefly first, mixable so that other apps' audio isn't interrupted.
        private func readSessionSampleRate() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            if (try? session.setActive(true)) != nil {
                sampleRate = session.sampleRate
                try? session.setActive(false)
            } else {
                sampleRate = session.sampleRate
            }
            try session.setCategory(.playback)
        }

        private func observeSession() {
            let center = NotificationCenter.default
            let session = AVAudioSession.sharedInstance()
            observers = [
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: session,
                    queue: .main
                ) { [weak self] notification in
                    self?.onInterruption(notification)
                },
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: session,
                    queue: .main
                ) { [weak self] notification in
                    self?.onRouteChange(notification)
                },
                center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification,
                    object: session,
                    queue: .main
                ) { [weak self] _ in
                    self?.onMediaServicesReset()
                },
            ]
        }

        private func onInterruption(_ notification: Notification) {
            guard
                let rawType = notification.userInfo?[
                    AVAudioSessionInterruptionTypeKey
                ] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else {
                return
            }
            switch type {
            case .began:
                // The system has already stopped the unit
                if playState == .playing {
                    stop(into: .pending)
                    playingCallback(false)
                }
            case .ended:
                guard playState == .pending else {
                    return
                }
                let rawOptions =
                    notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                    as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: rawOptions
                )
                if !options.contains(.shouldResume) {
                    playState = .paused
                } else if start() {
                    playingCallback(true)
                }
            @unknown default:
                break
            }
        }

        // The output device went away, for example headphones were unplugged
        private func onRouteChange(_ notification: Notification) {
            guard
                let rawReason = notification.userInfo?[
                    AVAudioSessionRouteChangeReasonKey
                ] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: rawReason)
                    == .oldDeviceUnavailable
            else {
                return
            }
            let wasPlaying = playState == .playing
            // Also cancels resuming after an interruption
            stop()
            if wasPlaying {
                playingCallback(false)
            }
        }

        // The audio unit and the session's settings are gone. The next play
        // builds a new unit.
        private func onMediaServicesReset() {
            let wasPlaying = playState == .playing
            stop()
            audioUnit = nil
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            if wasPlaying {
                playingCallback(false)
            }
        }
    #endif
}
