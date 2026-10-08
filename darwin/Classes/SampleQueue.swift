import Accelerate
import os

// Two buffers of `capacity` interleaved float32 frames, shared between the
// main thread and the render thread.
//
// The render thread plays the front buffer, counting the frames it has read.
// Meanwhile the back buffer is filled by Dart. When the front buffer is used
// up, the render thread swaps the two if the back buffer is ready, and asks
// for the new back buffer to be filled. If it isn't ready, the render thread
// plays silence until it is.
//
// The fields are guarded by `lock`. The render thread only tries the lock, so
// it never waits for the main thread, which holds it just long enough to read
// or set a few fields. The samples of the back buffer are written without the
// lock: while it isn't ready, the render thread doesn't touch it.
final class SampleQueue {
    let channels: Int
    // Frames per buffer
    let capacity: Int
    var frameSize: Int { channels * MemoryLayout<Float>.size }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let storage: UnsafeMutablePointer<Float>

    // Guarded by lock
    private var front = 0
    private var frontFrames = 0
    private var readFrame = 0
    // Zero while the back buffer is not ready
    private var backFrames = 0
    private var gain: Float = 1

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        let samples = 2 * capacity * channels
        storage = .allocate(capacity: samples)
        storage.initialize(repeating: 0, count: samples)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        storage.deallocate()
    }

    var volume: Float {
        get { locked { gain } }
        set { locked { gain = newValue } }
    }

    // Main thread
    var needsSamples: Bool { locked { backFrames == 0 } }

    // Main thread. Copies a reply into the back buffer and makes it ready.
    // Returns the number of frames taken, at most `capacity`.
    func fill(from bytes: UnsafeRawBufferPointer) -> Int {
        let frames = min(bytes.count / frameSize, capacity)
        guard frames > 0, let source = bytes.baseAddress else {
            return 0
        }
        let back = locked { () -> Int? in
            backFrames == 0 ? front ^ 1 : nil
        }
        guard let back else {
            return 0
        }
        UnsafeMutableRawPointer(buffer(back)).copyMemory(
            from: source,
            byteCount: frames * frameSize
        )
        locked { backFrames = frames }
        return frames
    }

    // Render thread. Writes `frames` frames to `out`, padded with silence.
    // Returns whether the buffers were swapped, so the back buffer needs
    // samples.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        var written = 0
        var swapped = false
        if os_unfair_lock_trylock(lock) {
            var g = gain
            while written < frames {
                if readFrame == frontFrames {
                    if backFrames == 0 {
                        break
                    }
                    front ^= 1
                    frontFrames = backFrames
                    backFrames = 0
                    readFrame = 0
                    swapped = true
                }
                let n = min(frames - written, frontFrames - readFrame)
                vDSP_vsmul(
                    buffer(front) + readFrame * channels,
                    1,
                    &g,
                    out + written * channels,
                    1,
                    vDSP_Length(n * channels)
                )
                readFrame += n
                written += n
            }
            os_unfair_lock_unlock(lock)
        }
        if written < frames {
            (out + written * channels).update(
                repeating: 0,
                count: (frames - written) * channels
            )
        }
        return swapped
    }

    private func buffer(_ index: Int) -> UnsafeMutablePointer<Float> {
        storage + index * capacity * channels
    }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }
}
