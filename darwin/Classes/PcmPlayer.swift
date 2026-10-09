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
    private let sampleCallback: SampleCallback
    private let playingCallback: PlayingCallback

    // Set by setup
    private var queue: SampleQueue?
    private var signal: DispatchSourceUserDataAdd?
    private var sampleRate: Double = 0

    // Nil before setup, and after the media services were reset
    private var audioUnit: AUAudioUnit?
    private var hardwareRunning = false

    // Also set by setPlaying(true) before setup, so that setup starts playing
    private var playing = false
    private var requestPending = false
    private var gain: Float = 1

    #if os(iOS)
        private var resumeAfterInterruption = false
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
            gain = min(max(newValue, 0), 1)
            queue?.volume = gain
        }
    }

    func setup() throws -> (frequency: Int, channels: Int) {
        precondition(!isSetUp)

        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            observeSession()
        #endif

        let unit = try makeAudioUnit()
        #if os(iOS)
            sampleRate = session.sampleRate
        #else
            sampleRate = unit.outputBusses[0].format.sampleRate
        #endif
        if sampleRate <= 0 {
            sampleRate = 48000
        }
        #if os(iOS)
            // When the screen is locked, iOS renders 4096 frames at a time
            unit.maximumFramesToRender = 4096
        #endif

        // Each buffer must hold at least one render call, or every call that
        // swaps buffers would also run out
        let capacity = max(
            Int(sampleRate) / 20,
            Int(unit.maximumFramesToRender)
        )
        let queue = SampleQueue(channels: 2, capacity: capacity)
        queue.volume = gain
        self.queue = queue

        let signal = DispatchSource.makeUserDataAddSource(queue: .main)
        signal.setEventHandler { [weak self] in
            self?.requestSamples()
        }
        signal.activate()
        self.signal = signal

        try configure(unit)
        audioUnit = unit

        if playing {
            if !start() {
                playingCallback(false)
            }
        }
        return (Int(sampleRate), queue.channels)
    }

    func setPlaying(_ play: Bool) {
        #if os(iOS)
            resumeAfterInterruption = false
        #endif
        if play {
            if !start() {
                playingCallback(false)
            }
        } else {
            stop()
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            #endif
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
        return try AUAudioUnit(componentDescription: description)
    }

    // Sets the format and the render callback, and allocates the unit
    private func configure(_ unit: AUAudioUnit) throws {
        guard let queue, let signal,
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
        playing = true
        guard isSetUp else {
            // setup starts playing
            return true
        }
        if hardwareRunning {
            return true
        }
        do {
            #if os(iOS)
                try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if audioUnit == nil {
                let unit = try makeAudioUnit()
                #if os(iOS)
                    unit.maximumFramesToRender = 4096
                #endif
                try configure(unit)
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
            playing = false
            return false
        }
    }

    private func stop() {
        playing = false
        if hardwareRunning {
            audioUnit?.stopHardware()
            hardwareRunning = false
        }
    }

    private func requestSamples() {
        guard playing, !requestPending, let queue, queue.needsSamples else {
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
                if playing {
                    stop()
                    resumeAfterInterruption = true
                    playingCallback(false)
                }
            case .ended:
                guard resumeAfterInterruption else {
                    return
                }
                resumeAfterInterruption = false
                let rawOptions =
                    notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                    as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: rawOptions
                )
                if options.contains(.shouldResume) && start() {
                    playingCallback(true)
                }
            @unknown default:
                break
            }
        }

        // Like Android's ACTION_AUDIO_BECOMING_NOISY: headphones unplugged
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
            resumeAfterInterruption = false
            if playing {
                stop()
                playingCallback(false)
            }
        }

        // The audio unit and the session's settings are gone. The next play
        // builds a new unit.
        private func onMediaServicesReset() {
            resumeAfterInterruption = false
            let wasPlaying = playing
            stop()
            hardwareRunning = false
            audioUnit = nil
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            if wasPlaying {
                playingCallback(false)
            }
        }
    #endif
}
