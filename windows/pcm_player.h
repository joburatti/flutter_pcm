#pragma once

#include <expected>
#include <future>
#include <stdint.h>
#include <string>
#include <thread>

#include "windows.h"

#include "mmreg.h"

struct IAudioClient;
struct IAudioRenderClient;
struct ISimpleAudioVolume;

namespace flutter_pcm {
using ByteVectorPtr = std::unique_ptr<std::vector<uint8_t>>;
using SampleCallback = std::function<std::future<ByteVectorPtr>(uint32_t)>;
using VolumeCallback = std::function<void(float)>;

enum SampleFormat { unknown, float32, uint8, uint16 };

struct AudioFormat {
  uint32_t frequency;
  uint32_t channels;
  SampleFormat sample_format;
};

using SetupResult = std::expected<AudioFormat, std::string>;

class PcmPlayer {
public:
  enum PlayState { kPaused, kPlaying, kExiting };

  PcmPlayer(SampleCallback sample_callback, VolumeCallback volume_callback);
  ~PcmPlayer();

  PcmPlayer(const PcmPlayer &) = delete;
  PcmPlayer &operator=(const PcmPlayer &) = delete;

  SetupResult Setup();
  std::expected<std::monostate, std::string> Teardown();

  void set_play_state(PlayState s);
  void set_volume(float v);
  float get_volume() { return volume_; }

private:
  std::mutex mutex_;
  std::condition_variable cv_;

  std::thread audio_thread_;
  void ThreadRunner(std::promise<SetupResult> promise);
  void ThreadMainLoop(IAudioClient *audio_client,
                      IAudioRenderClient *render_client,
                      ISimpleAudioVolume *audio_volume,
                      uint32_t buffer_frame_count, WAVEFORMATEX *pwfx);

  std::atomic<PlayState> play_state_;
  std::atomic<float> volume_;
  std::atomic<bool> apply_volume_;

  const SampleCallback sample_callback_;
  const VolumeCallback volume_callback_;
};
} // namespace flutter_pcm