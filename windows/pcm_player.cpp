#include "pcm_player.h"

#include <audioclient.h>
#include <audiopolicy.h>
#include <chrono>
#include <initguid.h>
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

// todo: set error message in some way
#define CHECK_RESULT(name)                                                     \
  if (FAILED(hr)) {                                                            \
    return;                                                                    \
  }

#define CHECK_RESULT_MAIN_LOOP(name)                                           \
  if (FAILED(hr)) {                                                            \
    play_state_ = kExiting;                                                    \
    return;                                                                    \
  }

#define CHECK_RESULT_PROMISE(name)                                             \
  if (FAILED(hr)) {                                                            \
    promise.set_value(                                                         \
        std::unexpected(std::format("Error calling {}: {}", name, hr)));       \
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

public:
  AudioSessionEvents(const std::function<void(float)> &vc)
      : ref_count_(1), on_volume_change_(vc) {}

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
    case 1:
      return uint8;
    case 2:
      return uint16;
    }
    break;
  case WAVE_FORMAT_IEEE_FLOAT:
    return float32;
  }

  return unknown;
}

template <typename T> auto com_ptr() {
  auto dstr = [](T *ptr) { ptr->Release(); };
  return std::unique_ptr<T, decltype(dstr)>(nullptr, dstr);
}

PcmPlayer::PcmPlayer(SampleCallback sample_callback,
                     VolumeCallback volume_callback)
    : play_state_(kPaused), sample_callback_(sample_callback),
      volume_callback_(volume_callback), volume_(0), apply_volume_(false) {}

PcmPlayer::~PcmPlayer() { Teardown(); }

std::expected<AudioFormat, std::string> flutter_pcm::PcmPlayer::Setup() {
  if (audio_thread_.joinable()) {
    return std::unexpected("Setup has already been called");
  }

  std::promise<SetupResult> promise;
  auto future = promise.get_future();
  audio_thread_ =
      std::thread(&PcmPlayer::ThreadRunner, this, std::move(promise));

  return future.get();
}

std::expected<std::monostate, std::string> PcmPlayer::Teardown() {
  set_play_state(kExiting);
  if (audio_thread_.joinable()) {
    audio_thread_.join();
  }

  return {};
}

void PcmPlayer::set_play_state(PlayState s) {
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

void PcmPlayer::ThreadRunner(std::promise<SetupResult> promise) {
  HRESULT hr = CoInitializeEx(0, 0);
  CHECK_RESULT_PROMISE("CoInitializeEx");

  auto enumerator = com_ptr<IMMDeviceEnumerator>();
  hr = CoCreateInstance(CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
                        IID_IMMDeviceEnumerator, std::out_ptr(enumerator));
  CHECK_RESULT_PROMISE("CoCreateInstance");

  auto device = com_ptr<IMMDevice>();
  hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia,
                                           std::out_ptr(device));
  CHECK_RESULT_PROMISE("GetDefaultAudioEndpoint");

  auto audio_session_manager = com_ptr<IAudioSessionManager>();
  hr = device->Activate(IID_IAudioSessionManager, CLSCTX_INPROC_SERVER, NULL,
                        (void **)&audio_session_manager);
  CHECK_RESULT_PROMISE("Activate AudioSessionManager");

  auto events = com_ptr<IAudioSessionEvents>();
  events.reset(new AudioSessionEvents([this](float v) {
    volume_ = v;
    volume_callback_(v);
  }));

  auto release_session_control = [e = events.get()](IAudioSessionControl *asc) {
    asc->UnregisterAudioSessionNotification(e);
    asc->Release();
  };
  auto audio_session_control =
      std::unique_ptr<IAudioSessionControl, decltype(release_session_control)>(
          nullptr, release_session_control);
  hr = audio_session_manager->GetAudioSessionControl(
      &AUDIO_CLIENT_GUID, 0, std::out_ptr(audio_session_control));
  CHECK_RESULT_PROMISE("GetAudioSessionControl");

  hr = audio_session_control->RegisterAudioSessionNotification(events.get());
  CHECK_RESULT_PROMISE("RegisterAudioSessionNotification");

  auto audio_client = com_ptr<IAudioClient>();
  hr = device->Activate(IID_IAudioClient, CLSCTX_INPROC_SERVER, NULL,
                        (void **)&audio_client);
  CHECK_RESULT_PROMISE("Activate AudioClient");

  auto pwfx = std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)>(
      nullptr, CoTaskMemFree);
  hr = audio_client->GetMixFormat(std::out_ptr(pwfx));
  CHECK_RESULT_PROMISE("GetMixFormat");

  const auto format_tag = GetFormatTag(pwfx.get());
  const auto format = get_sample_format(format_tag, pwfx->wBitsPerSample);
  if (format == unknown) {
    promise.set_value(
        std::unexpected(std::format("Unknown format tag {}", format_tag)));
    return;
  }

  // The requested period here will be the minimum buffer length the driver
  // uses. If we request too short a buffer, the driver will make it longer.
  // We fill half of this buffer at a time. Go with 100ms for now.
  hr = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                REFTIMES_PER_SEC / 10, 0, pwfx.get(),
                                &AUDIO_CLIENT_GUID);
  CHECK_RESULT_PROMISE("Initialize");

  uint32_t buffer_frame_count;
  hr = audio_client->GetBufferSize(&buffer_frame_count);
  CHECK_RESULT_PROMISE("GetBufferSize");

  const auto buffer_duration =
      1000ms * buffer_frame_count / pwfx->nSamplesPerSec;

  auto render_client = com_ptr<IAudioRenderClient>();
  hr =
      audio_client->GetService(IID_IAudioRenderClient, (void **)&render_client);
  CHECK_RESULT_PROMISE("GetService AudioRenderClient");

  auto audio_volume = com_ptr<ISimpleAudioVolume>();
  hr = audio_client->GetService(IID_ISimpleAudioVolume, (void **)&audio_volume);
  CHECK_RESULT_PROMISE("GetService SimpleAudioVolume");

  float v = 0;
  audio_volume->GetMasterVolume(&v);
  volume_ = v;

  hr = audio_client->Start();
  CHECK_RESULT_PROMISE("Start");

  // Done initializing
  promise.set_value(AudioFormat{pwfx->nSamplesPerSec, pwfx->nChannels, format});

  while (play_state_ != kExiting) {
    ThreadMainLoop(audio_client.get(), render_client.get(), audio_volume.get(),
                   buffer_frame_count, pwfx.get());
  }

  hr = audio_client->Stop();
  CHECK_RESULT("Stop");

  hr = audio_client->Reset();
  CHECK_RESULT("Reset");
}

void PcmPlayer::ThreadMainLoop(IAudioClient *audio_client,
                               IAudioRenderClient *render_client,
                               ISimpleAudioVolume *audio_volume,
                               uint32_t buffer_frame_count,
                               WAVEFORMATEX *pwfx) {
  if (play_state_ == kPaused) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (play_state_ == kPaused) {
      cv_.wait(lock);
    }
  }

  if (apply_volume_) {
    audio_volume->SetMasterVolume(volume_, &CONTEXT_GUID);
  }

  if (play_state_ == kPlaying) {
    uint32_t num_frames_padding;
    HRESULT hr = audio_client->GetCurrentPadding(&num_frames_padding);
    CHECK_RESULT_MAIN_LOOP("GetCurrentPadding");

    // Should we wait a bit before filling the buffer?
    if (num_frames_padding > 3 * buffer_frame_count / 5) {
      // Wait until half the buffer is available
      uint32_t sleep_frames = num_frames_padding - buffer_frame_count / 2;
      auto sleep_duration = 1000ms * sleep_frames / pwfx->nSamplesPerSec;

      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait_for(lock, sleep_duration);

      // Did the user pause while we were waiting?
      if (play_state_ != kPlaying) {
        return;
      }

      // Get the new number of available frames after waiting
      hr = audio_client->GetCurrentPadding(&num_frames_padding);
      CHECK_RESULT_MAIN_LOOP("GetCurrentPadding2");
    }

    try {
      uint32_t frame_size_bytes = pwfx->wBitsPerSample * pwfx->nChannels / 8;
      uint32_t num_frames_available = buffer_frame_count - num_frames_padding;
      auto samples_future = sample_callback_(num_frames_available);

      std::future_status samples_status;
      do {
        samples_status = samples_future.wait_for(100ms);
      } while (play_state_ == kPlaying &&
               samples_status != std::future_status::ready);

      if (samples_status != std::future_status::ready) {
        return;
      }

      auto samples = samples_future.get();
      uint32_t frame_count = (uint32_t)min(num_frames_available,
                                           samples->size() / frame_size_bytes);

      uint8_t *buffer;
      hr = render_client->GetBuffer(frame_count, &buffer);
      CHECK_RESULT_MAIN_LOOP("GetBuffer");

      std::copy_n(samples->begin(), frame_count * frame_size_bytes, buffer);

      hr = render_client->ReleaseBuffer(frame_count, 0);
      CHECK_RESULT_MAIN_LOOP("ReleaseBuffer2");
    } catch (std::runtime_error const &) {
      return;
    }
  }
}

} // namespace flutter_pcm