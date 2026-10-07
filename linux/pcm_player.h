#pragma once

#include <pulse/pulseaudio.h>

#include <atomic>
#include <expected>
#include <functional>
#include <memory>
#include <stdint.h>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace flutter_pcm {
using ByteVectorPtr = std::unique_ptr<std::vector<uint8_t>>;
// Asks Dart for up to max_frames frames. The reply must be passed to
// PcmPlayer::OnSamples on the caller's thread.
using SampleCallback = std::function<void(uint32_t max_frames)>;
using VolumeCallback = std::function<void(float)>;
using PlayingCallback = std::function<void(bool)>;

// Names must match the Dart SampleFormat enum
enum SampleFormat { unknown, float32, float64, uint8, uint16, uint32 };
const char *sample_format_name(SampleFormat format);

struct AudioFormat {
  uint32_t frequency;
  uint32_t channels;
  SampleFormat sample_format;
};

using SetupResult = std::expected<AudioFormat, std::string>;

// Plays PCM through the PulseAudio client API (also served by pipewire-pulse).
//
// Threads involved:
// - the caller's thread (the GTK main thread) calls Setup/Teardown and the
//   setters,
// - the PulseAudio threaded mainloop runs all pa_* callbacks,
// - audio_thread_ requests samples through sample_callback_ and writes them
//   to the stream.
// All PulseAudio state is guarded by the mainloop lock, and
// pa_threaded_mainloop_wait/signal is the only condition variable.
//
// At most one getSamples request is outstanding. The audio thread doesn't
// block on it: the reply is handed over through OnSamples, and is played
// however late it comes. A reply that arrives while paused may be dropped:
// pausing is a glitch anyway, and this way a reply always fits the space
// that was free when it was requested, since nothing is written meanwhile.
//
// If the stream fails (e.g. the server restarted), the audio thread drops the
// context and stream, pauses playback and reports the pause through
// playing_callback_. It then waits, and on the next set_play_state(kPlaying)
// reconnects with the sample spec reported by Setup, since Dart keeps
// producing that format. If that fails, playback pauses again the same way.
class PcmPlayer {
public:
  enum PlayState { kPaused, kPlaying, kExiting };

  PcmPlayer(std::string app_name, SampleCallback sample_callback,
            VolumeCallback volume_callback, PlayingCallback playing_callback);
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
  using ConnectResult = std::expected<void, std::string>;
  SetupResult SetupLocked();
  ConnectResult ConnectContextLocked();
  ConnectResult ConnectStreamLocked(bool restore_volume);
  void DisconnectLocked();
  void PauseAfterFailureLocked();
  void ApplyVolumeLocked();
  template <typename T> bool WaitUntilReady(T *object);
  bool WaitForOperation(pa_operation *op);
  std::unexpected<std::string> ContextError(const char *name);

  void ThreadMainLoop();
  bool ReconnectLocked();

  static void OperationStateCallback(pa_operation *o, void *userdata);
  static void ContextStateCallback(pa_context *c, void *userdata);
  static void StreamStateCallback(pa_stream *s, void *userdata);
  static void StreamWriteCallback(pa_stream *s, size_t nbytes, void *userdata);
  static void ServerInfoCallback(pa_context *c, const pa_server_info *info,
                                 void *userdata);
  static void SubscribeCallback(pa_context *c, pa_subscription_event_type_t t,
                                uint32_t idx, void *userdata);
  static void SinkInputInfoCallback(pa_context *c, const pa_sink_input_info *i,
                                    int eol, void *userdata);
  static void SetVolumeCallback(pa_context *c, int success, void *userdata);

  pa_threaded_mainloop *mainloop_ = nullptr;
  pa_context *context_ = nullptr;
  pa_stream *stream_ = nullptr;
  pa_sample_spec sample_spec_ = {};
  size_t min_request_bytes_ = 0;

  // Caller's thread only
  std::thread audio_thread_;

  std::atomic<PlayState> play_state_;
  std::atomic<float> volume_;

  // Guarded by the mainloop lock
  bool request_pending_ = false;
  uint32_t requested_frames_ = 0;
  // A reply that hasn't been written yet
  ByteVectorPtr samples_;
  // Set by an empty or failed reply, so the next request waits a while
  bool delay_request_ = false;
  pa_volume_t pa_volume_ = PA_VOLUME_NORM;
  int pending_volume_sets_ = 0;
  bool notify_volume_changes_ = false;

  const std::string app_name_;
  const SampleCallback sample_callback_;
  const VolumeCallback volume_callback_;
  const PlayingCallback playing_callback_;
};
} // namespace flutter_pcm
