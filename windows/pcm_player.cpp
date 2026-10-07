#include "pcm_player.h"

#include <audioclient.h>
#include <audiopolicy.h>
#include <algorithm>
#include <chrono>
#include <format>
#include <initguid.h>
#include <optional>
#include <mmdeviceapi.h>
#include <windows.h>

using namespace std::chrono_literals;

const CLSID CLSID_MMDeviceEnumerator = __uuidof(MMDeviceEnumerator);
const IID IID_IMMDeviceEnumerator = __uuidof(IMMDeviceEnumerator);
const IID IID_IAudioClient = __uuidof(IAudioClient);
const IID IID_IAudioSessionManager = __uuidof(IAudioSessionManager);
const IID IID_IAudioRenderClient = __uuidof(IAudioRenderClient);
const IID IID_ISimpleAudioVolume = __uuidof(ISimpleAudioVolume);

const GUID CONTEXT_GUID = {0xDEADBEEF, 0xDEAD, 0xBEEF, 0xDE, 0xAD, 0xBE,
                           0xEF,       0xDE,   0xAD,   0xBE, 0xEF};
const GUID AUDIO_CLIENT_GUID = {0x01020304, 0x0506, 0x0708, 0x09, 0x0a, 0x0b,
                                0x0c,       0x0d,   0x0e,   0x0f, 0x00};

#define REFTIMES_PER_SEC 10000000
#define REFTIMES_PER_MILLISEC 10000

#define HRESULT_ERROR(name)                                                    \
  std::unexpected(                                                             \
      std::format("Error calling {}: {:#010x}", name, (uint32_t)hr))

// The device can't be used anymore, typically AUDCLNT_E_DEVICE_INVALIDATED
#define CHECK_RESULT_MAIN_LOOP(name)                                           \
  if (FAILED(hr)) {                                                            \
    return false;                                                              \
  }

#define CHECK_RESULT_SETUP(name)                                               \
  if (FAILED(hr)) {                                                            \
    return HRESULT_ERROR(name);                                                \
  }

#define CHECK_RESULT_PROMISE(name)                                             \
  if (FAILED(hr)) {                                                            \
    promise.set_value(HRESULT_ERROR(name));                                    \
    return;                                                                    \
  }

namespace flutter_pcm {
//-----------------------------------------------------------
// Client implementation of IAudioSessionEvents interface.
// WASAPI calls these methods to notify the application when
// a parameter or property of the audio session changes.
//-----------------------------------------------------------
class AudioSessionEvents : public IAudioSessionEvents {
  std::atomic<ULONG> ref_count_;
  const std::function<void(float)> on_volume_change_;
  const std::function<void()> on_disconnect_;

public:
  AudioSessionEvents(const std::function<void(float)> &volume_change,
                     const std::function<void()> &disconnect)
      : ref_count_(1), on_volume_change_(volume_change),
        on_disconnect_(disconnect) {}

  ~AudioSessionEvents() {}

  // IUnknown methods -- AddRef, Release, and QueryInterface

  ULONG STDMETHODCALLTYPE AddRef() { return ++ref_count_; }

  ULONG STDMETHODCALLTYPE Release() {
    ULONG refs = --ref_count_;
    if (0 == refs) {
      delete this;
    }
    return refs;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, VOID **ppvInterface) {
    if (IID_IUnknown == riid) {
      AddRef();
      *ppvInterface = (IUnknown *)this;
    } else if (__uuidof(IAudioSessionEvents) == riid) {
      AddRef();
      *ppvInterface = (IAudioSessionEvents *)this;
    } else {
      *ppvInterface = NULL;
      return E_NOINTERFACE;
    }
    return S_OK;
  }

  // Notification methods for audio session events

  HRESULT STDMETHODCALLTYPE OnDisplayNameChanged(LPCWSTR newDisplayName,
                                                 LPCGUID eventContext) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnIconPathChanged(LPCWSTR newIconPath,
                                              LPCGUID eventContext) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnSimpleVolumeChanged(float newVolume, BOOL newMute,
                                                  LPCGUID eventContext) {
    if (CONTEXT_GUID != *eventContext) {
      on_volume_change_(newVolume);
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  OnChannelVolumeChanged(DWORD channelCount, float newChannelVolumeArray[],
                         DWORD changedChannel, LPCGUID eventContext) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnGroupingParamChanged(LPCGUID newGroupingParam,
                                                   LPCGUID eventContext) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnStateChanged(AudioSessionState newState) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE
  OnSessionDisconnected(AudioSessionDisconnectReason disconnectReason) {
    // The device was removed, the audio service stopped, or similar. The
    // stream is unusable either way.
    on_disconnect_();
    return S_OK;
  }
};

uint32_t GetFormatTag(const WAVEFORMATEX *wfx) {
  if (wfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    if (wfx->cbSize < (sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)))
      return 0;

    static const GUID s_wfexBase = {0x00000000, 0x0000, 0x0010, 0x80,
                                    0x00,       0x00,   0xAA,   0x00,
                                    0x38,       0x9B,   0x71};

    auto wfex = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(wfx);
    if (memcmp(reinterpret_cast<const BYTE *>(&wfex->SubFormat) + sizeof(DWORD),
               reinterpret_cast<const BYTE *>(&s_wfexBase) + sizeof(DWORD),
               sizeof(GUID) - sizeof(DWORD)) != 0) {
      return 0;
    }

    return wfex->SubFormat.Data1;
  } else {
    return wfx->wFormatTag;
  }
}

SampleFormat get_sample_format(const uint32_t format_tag,
                               const uint32_t bits_per_sample) {
  switch (format_tag) {
  case WAVE_FORMAT_PCM:
    switch (bits_per_sample) {
    case 8:
      return uint8;
    case 16:
      return uint16;
    case 32:
      return uint32;
    }
    break;
  case WAVE_FORMAT_IEEE_FLOAT:
    return float32;
  }

  return unknown;
}

struct ComRelease {
  void operator()(IUnknown *p) const { p->Release(); }
};
template <typename T> using ComPtr = std::unique_ptr<T, ComRelease>;

// The objects belonging to one opening of the device. Lives on the audio
// thread, between CoInitializeEx and CoUninitialize.
struct PcmPlayer::Device {
  ComPtr<IAudioSessionEvents> events;
  ComPtr<IAudioSessionControl> session_control;
  ComPtr<IAudioClient> audio_client;
  ComPtr<IAudioRenderClient> render_client;
  ComPtr<ISimpleAudioVolume> audio_volume;
  uint32_t buffer_frame_count = 0;
  uint32_t sample_rate = 0;
  uint32_t frame_size = 0;

  ~Device() {
    if (audio_client) {
      // These fail if the device is gone, which doesn't matter here
      audio_client->Stop();
      audio_client->Reset();
    }
    if (session_control && events) {
      session_control->UnregisterAudioSessionNotification(events.get());
    }
  }
};

PcmPlayer::PcmPlayer(SampleCallback sample_callback,
                     VolumeCallback volume_callback,
                     PlayingCallback playing_callback)
    : play_state_(kPaused), volume_(0), apply_volume_(false),
      sample_callback_(std::move(sample_callback)),
      volume_callback_(std::move(volume_callback)),
      playing_callback_(std::move(playing_callback)) {}

PcmPlayer::~PcmPlayer() { Teardown(); }

SetupResult PcmPlayer::Setup() {
  if (set_up_) {
    return std::unexpected("Setup has already been called");
  }

  // The audio thread opens the device and reports the result
  std::promise<SetupResult> promise;
  auto future = promise.get_future();
  audio_thread_ =
      std::thread(&PcmPlayer::ThreadRunner, this, std::move(promise));

  auto result = future.get();
  if (!result) {
    audio_thread_.join();
  }
  set_up_ = result.has_value();
  if (set_up_) {
    auto pwfx = reinterpret_cast<const WAVEFORMATEX *>(wave_format_.data());
    frame_size_ = pwfx->nBlockAlign;
  }
  return result;
}

std::expected<std::monostate, std::string> PcmPlayer::Teardown() {
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    play_state_ = kExiting;
    cv_.notify_all();
  }
  if (audio_thread_.joinable()) {
    audio_thread_.join();
  }

  return {};
}

// Called on the audio thread after the device failed, or reopening it did.
// Pauses until the next set_play_state(kPlaying).
void PcmPlayer::PauseAfterFailure() {
  bool was_playing;
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    was_playing = play_state_ == kPlaying;
    if (was_playing) {
      play_state_ = kPaused;
    }
  }
  if (was_playing) {
    playing_callback_(false);
  }
}

void PcmPlayer::set_play_state(PlayState s) {
  // Without a device, the audio thread reopens it when woken up to play
  const std::lock_guard<std::mutex> lock(mutex_);
  play_state_ = s;
  cv_.notify_all();
}

void PcmPlayer::set_volume(float v) {
  const std::lock_guard<std::mutex> lock(mutex_);
  volume_ = v;
  apply_volume_ = true;
  cv_.notify_all();
}

// Exits when tearing down, or when opening the device failed during setup
// (reported through the promise). When the device fails later, pauses and
// waits to reopen it, see PauseAfterFailure.
void PcmPlayer::ThreadRunner(std::promise<SetupResult> promise) {
  HRESULT hr = CoInitializeEx(0, 0);
  CHECK_RESULT_PROMISE("CoInitializeEx");

  {
    // Empty while closed after a failure
    std::optional<Device> device;
    device.emplace();
    auto result = OpenDevice(*device);
    const bool opened = result.has_value();
    if (!opened) {
      device.reset();
    }
    promise.set_value(std::move(result));

    while (opened && play_state_ != kExiting) {
      if (device) {
        if (!ThreadMainLoop(*device)) {
          device.reset();
          PauseAfterFailure();
        }
        continue;
      }

      {
        // Woken by set_play_state
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return play_state_ != kPaused; });
      }
      if (play_state_ == kExiting) {
        break;
      }

      // Open the current default endpoint with the format reported by Setup
      device.emplace();
      if (auto reopened = OpenDevice(*device); !reopened) {
        device.reset();
        OutputDebugStringA(
            std::format("flutter_pcm: reopening the device failed: {}\n",
                        reopened.error())
                .c_str());
        PauseAfterFailure();
      }
    }
  }
  CoUninitialize();
}

SetupResult PcmPlayer::OpenDevice(Device &device) {
  // Set up already, so this is reopening the device after a failure
  const bool reopening = !wave_format_.empty();

  {
    const std::lock_guard<std::mutex> lock(mutex_);
    session_disconnected_ = false;
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr =
      CoCreateInstance(CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                       IID_IMMDeviceEnumerator, std::out_ptr(enumerator));
  CHECK_RESULT_SETUP("CoCreateInstance");

  ComPtr<IMMDevice> endpoint;
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia,
                                           std::out_ptr(endpoint));
  CHECK_RESULT_SETUP("GetDefaultAudioEndpoint");

  ComPtr<IAudioSessionManager> audio_session_manager;
  hr = endpoint->Activate(IID_IAudioSessionManager, CLSCTX_INPROC_SERVER, NULL,
                          std::out_ptr(audio_session_manager));
  CHECK_RESULT_SETUP("Activate AudioSessionManager");

  device.events.reset(new AudioSessionEvents(
      [this](float v) {
        volume_ = v;
        volume_callback_(v);
      },
      [this] {
        const std::lock_guard<std::mutex> lock(mutex_);
        session_disconnected_ = true;
        cv_.notify_all();
      }));

  hr = audio_session_manager->GetAudioSessionControl(
      &AUDIO_CLIENT_GUID, 0, std::out_ptr(device.session_control));
  CHECK_RESULT_SETUP("GetAudioSessionControl");

  hr = device.session_control->RegisterAudioSessionNotification(
      device.events.get());
  CHECK_RESULT_SETUP("RegisterAudioSessionNotification");

  hr = endpoint->Activate(IID_IAudioClient, CLSCTX_INPROC_SERVER, NULL,
                          std::out_ptr(device.audio_client));
  CHECK_RESULT_SETUP("Activate AudioClient");

  // Use the device's mix format, unless reopening: Dart keeps producing the
  // format reported by Setup, which the new device may not share
  std::vector<uint8_t> wave_format = wave_format_;
  if (!reopening) {
    auto mix_format = std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)>(
        nullptr, CoTaskMemFree);
    hr = device.audio_client->GetMixFormat(std::out_ptr(mix_format));
    CHECK_RESULT_SETUP("GetMixFormat");

    auto bytes = reinterpret_cast<const uint8_t *>(mix_format.get());
    wave_format.assign(bytes,
                       bytes + sizeof(WAVEFORMATEX) + mix_format->cbSize);
  }
  auto pwfx = reinterpret_cast<const WAVEFORMATEX *>(wave_format.data());

  const auto format_tag = GetFormatTag(pwfx);
  const auto format = get_sample_format(format_tag, pwfx->wBitsPerSample);
  if (format == unknown) {
    return std::unexpected(std::format("Unknown format tag {}", format_tag));
  }

  // The requested period here will be the minimum buffer length the driver
  // uses. If we request too short a buffer, the driver will make it longer.
  // We fill half of this buffer at a time. Go with 100ms for now.
  // Windows converts the format if it isn't the mix format, which can
  // happen when reopening.
  hr = device.audio_client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
          AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
      REFTIMES_PER_SEC / 10, 0, pwfx, &AUDIO_CLIENT_GUID);
  CHECK_RESULT_SETUP("Initialize");

  hr = device.audio_client->GetBufferSize(&device.buffer_frame_count);
  CHECK_RESULT_SETUP("GetBufferSize");

  hr = device.audio_client->GetService(IID_IAudioRenderClient,
                                       std::out_ptr(device.render_client));
  CHECK_RESULT_SETUP("GetService AudioRenderClient");

  hr = device.audio_client->GetService(IID_ISimpleAudioVolume,
                                       std::out_ptr(device.audio_volume));
  CHECK_RESULT_SETUP("GetService SimpleAudioVolume");

  if (reopening) {
    // The session on the new device has its own volume
    device.audio_volume->SetMasterVolume(volume_, &CONTEXT_GUID);
  } else {
    float v = 0;
    device.audio_volume->GetMasterVolume(&v);
    volume_ = v;
  }

  hr = device.audio_client->Start();
  CHECK_RESULT_SETUP("Start");

  device.sample_rate = pwfx->nSamplesPerSec;
  device.frame_size = pwfx->nBlockAlign;
  const AudioFormat audio_format{pwfx->nSamplesPerSec, pwfx->nChannels, format};
  if (!reopening) {
    wave_format_ = std::move(wave_format);
  }
  return audio_format;
}

// Returns false if the device has failed
bool PcmPlayer::ThreadMainLoop(Device &device) {
  {
    std::unique_lock<std::mutex> lock(mutex_);
    if (play_state_ == kPaused && !apply_volume_ && !session_disconnected_) {
      cv_.wait(lock);
    }
    if (session_disconnected_) {
      return false;
    }
  }

  if (apply_volume_.exchange(false)) {
    device.audio_volume->SetMasterVolume(volume_, &CONTEXT_GUID);
  }

  if (play_state_ != kPlaying) {
    return true;
  }

  const uint32_t buffer_frame_count = device.buffer_frame_count;
  uint32_t num_frames_padding;
  HRESULT hr = device.audio_client->GetCurrentPadding(&num_frames_padding);
  CHECK_RESULT_MAIN_LOOP("GetCurrentPadding");

  // Below, waits are cut short by play state and volume changes, replies and
  // disconnects; the next round then looks again
  std::unique_lock<std::mutex> lock(mutex_);

  if (samples_) {
    // Fits, since nothing has been written since the request. Only a
    // reopened device may have a smaller buffer; the rest is dropped then.
    const uint32_t frame_count = (uint32_t)std::min<size_t>(
        buffer_frame_count - num_frames_padding,
        samples_->size() / device.frame_size);

    uint8_t *buffer;
    hr = device.render_client->GetBuffer(frame_count, &buffer);
    CHECK_RESULT_MAIN_LOOP("GetBuffer");

    std::copy_n(samples_->data(), frame_count * device.frame_size, buffer);

    hr = device.render_client->ReleaseBuffer(frame_count, 0);
    CHECK_RESULT_MAIN_LOOP("ReleaseBuffer");
    samples_.reset();
    return true;
  }

  // Wait until about half the buffer is free
  if (num_frames_padding > 3 * buffer_frame_count / 5) {
    uint32_t sleep_frames = num_frames_padding - buffer_frame_count / 2;
    cv_.wait_for(lock, 1000ms * sleep_frames / device.sample_rate);
    return true;
  }

  const uint32_t num_frames_available = buffer_frame_count - num_frames_padding;

  if (request_pending_) {
    cv_.wait(lock, [this] {
      return !request_pending_ || play_state_ != kPlaying || apply_volume_ ||
             session_disconnected_;
    });
    return true;
  }

  if (delay_request_) {
    // The last reply had nothing usable. Don't hammer the Dart side.
    delay_request_ = false;
    cv_.wait_for(lock,
                 1000ms * buffer_frame_count / 2 / device.sample_rate);
    return true;
  }

  request_pending_ = true;
  requested_frames_ = num_frames_available;
  lock.unlock();
  sample_callback_(num_frames_available);
  return true;
}

// Runs on the platform thread with the reply to the outstanding request, or
// nullptr if it failed
void PcmPlayer::OnSamples(ByteVectorPtr samples) {
  const std::lock_guard<std::mutex> lock(mutex_);
  if (!request_pending_) {
    return;
  }
  request_pending_ = false;

  // Only whole frames, and no more than requested
  if (samples) {
    const size_t bytes = std::min<size_t>(
        samples->size(), (size_t)requested_frames_ * frame_size_);
    samples->resize(bytes - bytes % frame_size_);
  }
  if (play_state_ != kPlaying) {
    // Dropped, see the class comment
  } else if (samples && !samples->empty()) {
    samples_ = std::move(samples);
  } else {
    delay_request_ = true;
  }
  cv_.notify_all();
}

} // namespace flutter_pcm
