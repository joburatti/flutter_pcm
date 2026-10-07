package com.example.flutter_pcm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.max
import kotlin.math.min
import android.media.AudioFormat as AndroidAudioFormat

// Names must match the Dart SampleFormat enum
@Suppress("EnumEntryName")
enum class SampleFormat { float32, float64, uint8, uint16, uint32 }

data class AudioFormat(val frequency: Int, val channels: Int, val sampleFormat: SampleFormat)

// Asks Dart for up to maxFrames frames. The reply must be passed to
// PcmPlayer.onSamples on the main thread.
typealias SampleCallback = (maxFrames: Int) -> Unit
typealias PlayingCallback = (playing: Boolean) -> Unit

// Plays PCM through an AudioTrack in streaming mode.
//
// Threads involved:
// - the main thread calls every public method and receives the audio focus
//   and becoming-noisy callbacks,
// - audioThread requests samples through sampleCallback and writes them to
//   the track.
// playState and the request state are shared between them, guarded by lock.
//
// At most one getSamples request is outstanding. The audio thread doesn't
// block on it: the reply is handed over through onSamples, and is played
// however late it comes. A reply that arrives while paused may be dropped:
// pausing is a glitch anyway, and this way a reply always fits the space
// that was free when it was requested, since nothing is written meanwhile.
//
// Playing requires audio focus. When the system takes playback away (focus
// loss, headphones unplugged), playingCallback reports it, and again when a
// transient focus loss ends and playback resumes by itself.
//
// PENDING means playback should start as soon as it can: when setup has run,
// if setPlaying(true) came before it, or when a transient focus loss ends.
// The audio thread treats it like PAUSED.
//
// If writing to the track fails (e.g. it died with the audioserver), playback
// pauses the same way and the track is dropped. The next setPlaying(true)
// builds a new one with the format reported by setup.
class PcmPlayer(
    context: Context,
    private val sampleCallback: SampleCallback,
    private val playingCallback: PlayingCallback,
) {
    private enum class PlayState { PAUSED, PLAYING, PENDING, EXITING }

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private val lock = ReentrantLock()
    private val stateChanged = lock.newCondition()

    // Changed on the main thread only, under lock
    @Volatile
    private var playState = PlayState.PAUSED

    // Guarded by lock
    private var requestPending = false
    private var requestedFrames = 0
    // A reply that hasn't been written yet
    private var samples: ByteBuffer? = null
    // Set by an empty or failed reply, so the next request waits a while
    private var delayRequest = false

    // Main thread only
    // Set by setup and kept when the track is rebuilt, since Dart produces
    // samples in this format
    private var format: AudioFormat? = null
    private var track: AudioTrack? = null
    private var audioThread: Thread? = null
    private var volume = 1f
    private var ducked = false
    private var focusRequest: AudioFocusRequest? = null
    private var noisyReceiverRegistered = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener(::onAudioFocusChange)

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                stopBySystem()
            }
        }
    }

    val isPlaying get() = playState == PlayState.PLAYING

    private val isPaused get() = playState == PlayState.PAUSED || playState == PlayState.PENDING

    fun setup(): AudioFormat {
        check(format == null) { "Setup has already been called" }

        // The mixer runs at the device's native rate in float stereo, so this
        // format avoids resampling and takes the fast path
        val frequency = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
            ?.toIntOrNull() ?: 48000
        val newFormat = AudioFormat(frequency, 2, SampleFormat.float32)
        createTrack(newFormat)
        format = newFormat

        if (playState == PlayState.PENDING) {
            setPlaying(true)
        }

        return newFormat
    }

    // Builds the track and starts its audio thread, paused
    private fun createTrack(format: AudioFormat) {
        val frequency = format.frequency
        val frameSize = format.channels * 4
        val trackFormat = AndroidAudioFormat.Builder()
            .setSampleRate(frequency)
            .setEncoding(AndroidAudioFormat.ENCODING_PCM_FLOAT)
            .setChannelMask(AndroidAudioFormat.CHANNEL_OUT_STEREO)
            .build()

        val minBufferBytes = AudioTrack.getMinBufferSize(
            frequency, AndroidAudioFormat.CHANNEL_OUT_STEREO, AndroidAudioFormat.ENCODING_PCM_FLOAT,
        )
        check(minBufferBytes > 0) { "Error calling AudioTrack.getMinBufferSize: $minBufferBytes" }

        val newTrack = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(trackFormat)
            .setBufferSizeInBytes(max(minBufferBytes, frequency * frameSize * TARGET_LATENCY_MS / 1000))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (newTrack.state != AudioTrack.STATE_INITIALIZED) {
            newTrack.release()
            error("AudioTrack failed to initialize")
        }
        track = newTrack
        applyVolume()

        audioThread = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            threadMainLoop(newTrack, frameSize)
        }, "flutter_pcm audio").apply { start() }
    }

    // Rebuilds the track if a failure dropped it
    private fun ensureTrack(format: AudioFormat): Boolean {
        if (track != null) {
            return true
        }
        return try {
            createTrack(format)
            true
        } catch (e: RuntimeException) {
            Log.e(TAG, "Rebuilding the AudioTrack failed", e)
            false
        }
    }

    // Posted by the audio thread, which has exited
    private fun onTrackFailed(failedTrack: AudioTrack) {
        // Already released or rebuilt
        if (track !== failedTrack) {
            return
        }
        stopBySystem()
        audioThread?.join()
        audioThread = null
        failedTrack.release()
        track = null
    }

    fun release() {
        lock.withLock {
            playState = PlayState.EXITING
            stateChanged.signalAll()
        }
        audioThread?.join()
        audioThread = null

        abandonFocus()
        unregisterNoisyReceiver()
        track?.release()
        track = null
    }

    // Called on behalf of the app. When focus is denied (e.g. during a phone
    // call) playback stays paused and playingCallback reports it.
    fun setPlaying(nextPlaying: Boolean) {
        val format = format ?: run {
            // Started by setup
            setPlayState(if (nextPlaying) PlayState.PENDING else PlayState.PAUSED)
            return
        }

        if (nextPlaying) {
            if (!isPlaying) {
                if (ensureTrack(format) && requestFocus()) {
                    startPlayback()
                } else {
                    setPlayState(PlayState.PAUSED)
                    playingCallback(false)
                }
            }
        } else {
            abandonFocus()
            pausePlayback(PlayState.PAUSED)
            unregisterNoisyReceiver()
        }
    }

    fun setVolume(v: Float) {
        volume = v.coerceIn(0f, 1f)
        applyVolume()
    }

    fun getVolume() = volume

    private fun applyVolume() {
        track?.setVolume(if (ducked) volume * DUCK_GAIN else volume)
    }

    private fun setPlayState(next: PlayState) {
        lock.withLock {
            playState = next
            stateChanged.signalAll()
        }
    }

    private fun startPlayback() {
        val t = track ?: return
        t.play()
        registerNoisyReceiver()
        setPlayState(PlayState.PLAYING)
    }

    // Pauses into PAUSED, or PENDING to resume when focus comes back
    private fun pausePlayback(next: PlayState) {
        setPlayState(next)
        track?.pause()
    }

    // Pauses until focus comes back. The noisy receiver stays registered, so
    // unplugging the headphones meanwhile cancels the resume.
    private fun pauseUntilFocusGain() {
        if (!isPlaying) {
            return
        }
        pausePlayback(PlayState.PENDING)
        playingCallback(false)
    }

    // Pauses until the app plays again, also when only a resume was pending
    private fun stopBySystem() {
        abandonFocus()
        unregisterNoisyReceiver()
        val wasPlaying = isPlaying
        if (playState != PlayState.PAUSED) {
            pausePlayback(PlayState.PAUSED)
        }
        if (wasPlaying) {
            playingCallback(false)
        }
    }

    private fun onAudioFocusChange(focusChange: Int) {
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> stopBySystem()

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> pauseUntilFocusGain()

            // Since Android 8 the system ducks by itself
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    ducked = true
                    applyVolume()
                }

            AudioManager.AUDIOFOCUS_GAIN -> {
                if (ducked) {
                    ducked = false
                    applyVolume()
                }
                if (playState == PlayState.PENDING) {
                    startPlayback()
                    playingCallback(true)
                }
            }
        }
    }

    private fun requestFocus(): Boolean {
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(focusListener, mainHandler)
                .build()
                .also { focusRequest = it }
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusListener)
        }
        if (ducked) {
            ducked = false
            applyVolume()
        }
    }

    private fun registerNoisyReceiver() {
        if (noisyReceiverRegistered) {
            return
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(noisyReceiver, filter)
        }
        noisyReceiverRegistered = true
    }

    private fun unregisterNoisyReceiver() {
        if (noisyReceiverRegistered) {
            appContext.unregisterReceiver(noisyReceiver)
            noisyReceiverRegistered = false
        }
    }

    // Waits until about half the buffer is free, requests that many frames
    // from Dart and writes the reply, same as on Windows and Linux. Writes
    // are non-blocking so that pausing (which stops the playback head) can
    // never stall the thread.
    private fun threadMainLoop(track: AudioTrack, frameSize: Int) {
        val bufferFrames = track.bufferSizeInFrames
        val minRequestFrames = bufferFrames / 2
        val minRequestMs = max(1L, minRequestFrames * 1000L / track.sampleRate)
        var framesWritten = 0L
        var underrunCount = track.underrunCount
        var refilling = false

        while (true) {
            lock.withLock {
                if (isPaused) {
                    // Like after an underrun, play() only starts the track
                    // once its buffer is full
                    refilling = true
                    while (isPaused) {
                        stateChanged.await()
                    }
                }
            }
            if (playState == PlayState.EXITING) {
                return
            }

            // The playback head is an unsigned 32-bit frame counter that wraps
            val head = track.playbackHeadPosition.toLong() and 0xffffffffL
            val queued = (framesWritten - head) and 0xffffffffL
            val writable = (bufferFrames - queued).toInt()

            // After an underrun the track only starts again once its buffer
            // is full, so fill it up instead of waiting for half of it to
            // become free, which would never happen
            if (track.underrunCount != underrunCount) {
                underrunCount = track.underrunCount
                refilling = true
            }
            if (writable == 0) {
                refilling = false
            }
            val requestFrames = if (refilling) 1 else minRequestFrames

            // Waits below are cut short by play state changes and replies;
            // the next round then looks again
            val toWrite = lock.withLock {
                val s = samples
                when {
                    playState != PlayState.PLAYING -> {}

                    s != null -> {
                        samples = null
                        return@withLock s
                    }

                    writable < requestFrames -> stateChanged.await(
                        max(1L, (requestFrames - writable) * 1000L / track.sampleRate),
                        TimeUnit.MILLISECONDS,
                    )

                    requestPending -> stateChanged.await()

                    delayRequest -> {
                        // The last reply had nothing usable. Don't hammer
                        // the Dart side.
                        delayRequest = false
                        stateChanged.await(minRequestMs, TimeUnit.MILLISECONDS)
                    }

                    else -> {
                        requestPending = true
                        requestedFrames = writable
                        sampleCallback(writable)
                    }
                }
                null
            } ?: continue

            val written = track.write(toWrite, toWrite.remaining(), AudioTrack.WRITE_NON_BLOCKING)
            if (written < 0) {
                // The track can't be used anymore (ERROR_DEAD_OBJECT), or a
                // bug. Either way pause and let the next play rebuild it.
                Log.e(TAG, "AudioTrack.write failed: $written")
                mainHandler.post { onTrackFailed(track) }
                return
            }
            framesWritten += written / frameSize
            // Fits, since nothing has been written since the request. Only a
            // rebuilt track may have a smaller buffer; the rest is dropped then.
            if (toWrite.hasRemaining()) {
                Log.w(TAG, "Dropped ${toWrite.remaining()} bytes that didn't fit")
            }
        }
    }

    // Called on the main thread with the reply to the outstanding request,
    // or null if it failed
    fun onSamples(bytes: ByteArray?) {
        val frameSize = (format ?: return).channels * 4
        lock.withLock {
            if (!requestPending) {
                return
            }
            requestPending = false

            // Only whole frames, and no more than requested
            val usable = bytes?.let { min(it.size, requestedFrames * frameSize) } ?: 0
            if (playState != PlayState.PLAYING) {
                // Dropped, see the class comment
            } else if (usable >= frameSize) {
                samples = ByteBuffer.wrap(bytes!!, 0, usable - usable % frameSize)
            } else {
                delayRequest = true
            }
            stateChanged.signalAll()
        }
    }

    private companion object {
        const val TAG = "flutter_pcm"

        // Target amount of buffered audio, same as on Windows and Linux
        const val TARGET_LATENCY_MS = 100

        // Volume applied while another app holds transient focus that allows
        // ducking (before Android 8, where the system doesn't duck for us)
        const val DUCK_GAIN = 0.2f
    }
}
