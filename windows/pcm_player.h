#pragma once

#include <atomic>
#include <condition_variable>
#include <expected>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <stdint.h>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "windows.h"

#include "mmreg.h"

namespace flutter_pcm {
using ByteVectorPtr = std::unique_ptr<std::vector<uint8_t>>;
// Asks Dart for up to max_frames frames. The reply must be passed to
// PcmPlayer::OnSamples on the platform thread.
using SampleCallback = std::function<void(uint32_t max_frames)>;
using VolumeCallback = std::function<void(float)>;
using PlayingCallback = std::function<void(bool)>;

enum SampleFormat { unknown, float32, float64, uint8, uint16, uint32 };

struct AudioFormat {
  uint32_t frequency;
  uint32_t channels;
  SampleFormat sample_format;
};

using SetupResult = std::expected<AudioFormat, std::string>;

// Plays PCM through WASAPI in shared mode on the default render endpoint.
//
// At most one getSamples request is outstanding. The audio thread doesn't
// block on it: the reply is handed over through OnSamples, and is played
// however late it comes. A reply that arrives while paused may be dropped:
// pausing is a glitch anyway, and this way a reply always fits the space
// that was free when it was requested, since nothing is written meanwhile.
//
// If the device fails (typically AUDCLNT_E_DEVICE_INVALIDATED when it was
// unplugged or disabled), the audio thread releases it, pauses playback and
// reports the pause through playing_callback_. It then waits, and on the next
// set_play_state(kPlaying) opens the current default endpoint with the format
// reported by Setup, since Dart keeps producing that format, and lets Windows
// convert it. If that fails, playback pauses again the same way.
class PcmPlayer {
public:
  enum PlayState { kPaused, kPlaying, kExiting };

  PcmPlayer(SampleCallback sample_callback, VolumeCallback volume_callback,
            PlayingCallback playing_callback);
  ~PcmPlayer();

  PcmPlayer(const PcmPlayer &) = delete;
  PcmPlayer &operator=(const PcmPlayer &) = delete;

  SetupResult Setup();
  void Teardown();

  void OnSamples(ByteVectorPtr samples);

  void set_play_state(PlayState s);
  void set_volume(float v);
  float get_volume() { return volume_; }

private:
  struct Device;

  std::mutex mutex_;
  std::condition_variable cv_;

  std::thread audio_thread_;
  void ThreadRunner(std::promise<SetupResult> promise);
  SetupResult OpenDevice(Device &device);
  bool ThreadMainLoop(Device &device);
  void PauseAfterFailure();

  // Platform thread only
  bool set_up_ = false;
  uint32_t frame_size_ = 0;

  // The WAVEFORMATEX (with its extension) reported by Setup, reused when the
  // device is reopened. Written by the audio thread before it fulfills the
  // setup promise.
  std::vector<uint8_t> wave_format_;

  std::atomic<PlayState> play_state_;
  std::atomic<float> volume_;
  std::atomic<bool> apply_volume_;
  // Guarded by mutex_
  // Set when WASAPI disconnects the session, so that a paused audio thread
  // notices too
  bool session_disconnected_ = false;
  bool request_pending_ = false;
  uint32_t requested_frames_ = 0;
  // A reply that hasn't been written yet
  ByteVectorPtr samples_;
  // Set by an empty or failed reply, so the next request waits a while
  bool delay_request_ = false;

  const SampleCallback sample_callback_;
  const VolumeCallback volume_callback_;
  const PlayingCallback playing_callback_;
};
} // namespace flutter_pcm
