#pragma once

#include <pulse/pulseaudio.h>

#include <atomic>
#include <expected>
#include <functional>
#include <future>
#include <memory>
#include <stdint.h>
#include <string>
#include <thread>
#include <vector>

namespace flutter_pcm {
using ByteVectorPtr = std::unique_ptr<std::vector<uint8_t>>;
using SampleCallback = std::function<std::future<ByteVectorPtr>(uint32_t)>;
using VolumeCallback = std::function<void(float)>;

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
// - audio_thread_ pulls samples through sample_callback_ and writes them to
//   the stream.
// All PulseAudio state is guarded by the mainloop lock, and
// pa_threaded_mainloop_wait/signal is the only condition variable.
class PcmPlayer {
public:
  enum PlayState { kPaused, kPlaying, kExiting };

  PcmPlayer(std::string app_name, SampleCallback sample_callback,
            VolumeCallback volume_callback);
  ~PcmPlayer();

  PcmPlayer(const PcmPlayer &) = delete;
  PcmPlayer &operator=(const PcmPlayer &) = delete;

  SetupResult Setup();
  void Teardown();

  void set_play_state(PlayState s);
  void set_volume(float v);
  float get_volume() { return volume_; }

private:
  SetupResult SetupLocked();
  template <typename T> bool WaitUntilReady(T *object);
  bool WaitForOperation(pa_operation *op);
  std::unexpected<std::string> ContextError(const char *name);

  void ThreadMainLoop();
  ByteVectorPtr RequestSamples(uint32_t max_frames);

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

  std::thread audio_thread_;

  std::atomic<PlayState> play_state_;
  std::atomic<float> volume_;

  // Guarded by the mainloop lock
  pa_volume_t pa_volume_ = PA_VOLUME_NORM;
  int pending_volume_sets_ = 0;
  bool notify_volume_changes_ = false;

  const std::string app_name_;
  const SampleCallback sample_callback_;
  const VolumeCallback volume_callback_;
};
} // namespace flutter_pcm
