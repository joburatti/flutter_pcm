#include "pcm_player.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <format>

namespace flutter_pcm {

namespace {
// Target amount of buffered audio. Samples are requested from Dart whenever
// half of it has been played, same as on Windows.
constexpr pa_usec_t kTargetLatency = 100 * PA_USEC_PER_MSEC;

enum class Readiness { kPending, kReady, kFailed };

Readiness readiness(pa_context *c) {
  const auto state = pa_context_get_state(c);
  if (state == PA_CONTEXT_READY) {
    return Readiness::kReady;
  }
  return PA_CONTEXT_IS_GOOD(state) ? Readiness::kPending : Readiness::kFailed;
}

Readiness readiness(pa_stream *s) {
  const auto state = pa_stream_get_state(s);
  if (state == PA_STREAM_READY) {
    return Readiness::kReady;
  }
  return PA_STREAM_IS_GOOD(state) ? Readiness::kPending : Readiness::kFailed;
}

void unref_operation(pa_operation *op) {
  if (op) {
    pa_operation_unref(op);
  }
}

// Picks the sample format we ask the server for. The server's default format
// is used when we can express it; otherwise fall back to float32 and let the
// server convert.
SampleFormat choose_sample_format(pa_sample_format_t &format) {
  switch (format) {
  case PA_SAMPLE_FLOAT32NE:
    return float32;
  case PA_SAMPLE_S16NE:
    return uint16;
  case PA_SAMPLE_S32NE:
    return uint32;
  case PA_SAMPLE_U8:
    return uint8;
  default:
    format = PA_SAMPLE_FLOAT32NE;
    return float32;
  }
}
} // namespace

const char *sample_format_name(SampleFormat format) {
  switch (format) {
  case float32:
    return "float32";
  case float64:
    return "float64";
  case uint8:
    return "uint8";
  case uint16:
    return "uint16";
  case uint32:
    return "uint32";
  default:
    return "unknown";
  }
}

PcmPlayer::PcmPlayer(std::string app_name, SampleCallback sample_callback,
                     VolumeCallback volume_callback,
                     PlayingCallback playing_callback)
    : play_state_(kPaused), volume_(1), app_name_(std::move(app_name)),
      sample_callback_(std::move(sample_callback)),
      volume_callback_(std::move(volume_callback)),
      playing_callback_(std::move(playing_callback)) {}

PcmPlayer::~PcmPlayer() { Teardown(); }

SetupResult PcmPlayer::Setup() {
  if (mainloop_) {
    return std::unexpected("Setup has already been called");
  }

  if (play_state_ == kExiting) {
    play_state_ = kPaused;
  }

  mainloop_ = pa_threaded_mainloop_new();
  if (!mainloop_) {
    return std::unexpected("Error calling pa_threaded_mainloop_new");
  }

  if (pa_threaded_mainloop_start(mainloop_) < 0) {
    Teardown();
    return std::unexpected("Error calling pa_threaded_mainloop_start");
  }

  pa_threaded_mainloop_lock(mainloop_);
  auto result = SetupLocked();
  pa_threaded_mainloop_unlock(mainloop_);

  if (!result) {
    Teardown();
    return result;
  }

  audio_thread_ = std::thread(&PcmPlayer::ThreadMainLoop, this);
  return result;
}

SetupResult PcmPlayer::SetupLocked() {
  if (auto connected = ConnectContextLocked(); !connected) {
    return std::unexpected(connected.error());
  }

  // Use the server's default format, like the mix format on Windows
  if (!WaitForOperation(
          pa_context_get_server_info(context_, ServerInfoCallback, this))) {
    return ContextError("pa_context_get_server_info");
  }

  const auto sample_format = choose_sample_format(sample_spec_.format);
  if (!pa_sample_spec_valid(&sample_spec_)) {
    return std::unexpected("Server reported an invalid sample spec");
  }

  if (auto connected = ConnectStreamLocked(false); !connected) {
    return std::unexpected(connected.error());
  }

  return AudioFormat{sample_spec_.rate, sample_spec_.channels, sample_format};
}

PcmPlayer::ConnectResult PcmPlayer::ConnectContextLocked() {
  context_ = pa_context_new(pa_threaded_mainloop_get_api(mainloop_),
                            app_name_.c_str());
  if (!context_) {
    return std::unexpected("Error calling pa_context_new");
  }

  pa_context_set_state_callback(context_, ContextStateCallback, this);
  if (pa_context_connect(context_, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) <
      0) {
    return ContextError("pa_context_connect");
  }

  if (!WaitUntilReady(context_)) {
    return ContextError("pa_context_connect");
  }

  return {};
}

// Creates the stream with sample_spec_. When reconnecting after a failure,
// restore_volume applies our volume to the new sink input; otherwise the
// volume is read from it.
PcmPlayer::ConnectResult PcmPlayer::ConnectStreamLocked(bool restore_volume) {
  stream_ = pa_stream_new(context_, "PCM playback", &sample_spec_, nullptr);
  if (!stream_) {
    return ContextError("pa_stream_new");
  }

  pa_stream_set_state_callback(stream_, StreamStateCallback, this);
  pa_stream_set_write_callback(stream_, StreamWriteCallback, this);

  const uint32_t target_bytes =
      (uint32_t)pa_usec_to_bytes(kTargetLatency, &sample_spec_);
  pa_buffer_attr attr;
  attr.maxlength = (uint32_t)-1;
  attr.tlength = target_bytes;
  attr.prebuf = (uint32_t)-1;
  attr.minreq = target_bytes / 2;
  attr.fragsize = (uint32_t)-1;

  int flags = PA_STREAM_ADJUST_LATENCY;
  const bool corked = play_state_ != kPlaying;
  if (corked) {
    flags |= PA_STREAM_START_CORKED;
  }

  if (pa_stream_connect_playback(stream_, nullptr, &attr,
                                 (pa_stream_flags_t)flags, nullptr,
                                 nullptr) < 0) {
    return ContextError("pa_stream_connect_playback");
  }

  if (!WaitUntilReady(stream_)) {
    return ContextError("pa_stream_connect_playback");
  }

  // set_play_state doesn't cork a stream that isn't ready yet, so catch up
  // with changes made while the lock was released above
  if (corked != (play_state_ != kPlaying)) {
    unref_operation(pa_stream_cork(stream_, !corked, nullptr, nullptr));
  }

  // The server may have adjusted the buffer sizes
  min_request_bytes_ = pa_stream_get_buffer_attr(stream_)->minreq;

  // Follow the stream's volume (the "session volume" in the system mixer)
  pa_context_set_subscribe_callback(context_, SubscribeCallback, this);
  if (!WaitForOperation(pa_context_subscribe(
          context_, PA_SUBSCRIPTION_MASK_SINK_INPUT, nullptr, nullptr))) {
    return ContextError("pa_context_subscribe");
  }

  if (restore_volume) {
    ApplyVolumeLocked();
  } else if (!WaitForOperation(pa_context_get_sink_input_info(
                 context_, pa_stream_get_index(stream_), SinkInputInfoCallback,
                 this))) {
    return ContextError("pa_context_get_sink_input_info");
  }
  notify_volume_changes_ = true;

  return {};
}

// Drops the stream and context, keeping the mainloop
void PcmPlayer::DisconnectLocked() {
  notify_volume_changes_ = false;
  if (stream_) {
    pa_stream_set_state_callback(stream_, nullptr, nullptr);
    pa_stream_set_write_callback(stream_, nullptr, nullptr);
    pa_stream_disconnect(stream_);
    pa_stream_unref(stream_);
    stream_ = nullptr;
  }
  if (context_) {
    pa_context_set_subscribe_callback(context_, nullptr, nullptr);
    pa_context_set_state_callback(context_, nullptr, nullptr);
    pa_context_disconnect(context_);
    pa_context_unref(context_);
    context_ = nullptr;
  }
  // Replies to volume changes on the old context never arrive
  pending_volume_sets_ = 0;
}

void PcmPlayer::Teardown() {
  if (!mainloop_) {
    return;
  }

  pa_threaded_mainloop_lock(mainloop_);
  play_state_ = kExiting;
  pa_threaded_mainloop_signal(mainloop_, 0);
  pa_threaded_mainloop_unlock(mainloop_);

  if (audio_thread_.joinable()) {
    audio_thread_.join();
  }

  pa_threaded_mainloop_lock(mainloop_);
  DisconnectLocked();
  pa_threaded_mainloop_unlock(mainloop_);

  pa_threaded_mainloop_stop(mainloop_);
  pa_threaded_mainloop_free(mainloop_);
  mainloop_ = nullptr;
}

// Called on the audio thread after the stream failed, or reconnecting did.
// Drops the context and stream, keeping the mainloop, and pauses until the
// next set_play_state(kPlaying).
void PcmPlayer::PauseAfterFailureLocked() {
  DisconnectLocked();
  if (play_state_ == kPlaying) {
    play_state_ = kPaused;
    playing_callback_(false);
  }
}

// Called on the audio thread after a failure dropped the stream. Connects
// with the format reported by Setup, letting the server convert if its
// default has changed. Returns false if that failed.
bool PcmPlayer::ReconnectLocked() {
  auto result = ConnectContextLocked().and_then(
      [this] { return ConnectStreamLocked(true); });
  if (!result) {
    std::fprintf(stderr, "flutter_pcm: reconnecting failed: %s\n",
                 result.error().c_str());
  }
  return result.has_value();
}

void PcmPlayer::set_play_state(PlayState s) {
  if (!mainloop_) {
    play_state_ = s;
    return;
  }

  // Without a stream, the audio thread reconnects when woken up to play
  pa_threaded_mainloop_lock(mainloop_);
  play_state_ = s;
  if (stream_ && pa_stream_get_state(stream_) == PA_STREAM_READY &&
      s != kExiting) {
    unref_operation(
        pa_stream_cork(stream_, s == kPaused ? 1 : 0, nullptr, nullptr));
  }
  pa_threaded_mainloop_signal(mainloop_, 0);
  pa_threaded_mainloop_unlock(mainloop_);
}

void PcmPlayer::set_volume(float v) {
  v = std::clamp(v, 0.0f, 1.0f);
  volume_ = v;

  if (!mainloop_) {
    return;
  }

  pa_threaded_mainloop_lock(mainloop_);
  ApplyVolumeLocked();
  pa_threaded_mainloop_unlock(mainloop_);
}

// Sets the sink input volume to volume_
void PcmPlayer::ApplyVolumeLocked() {
  if (!stream_) {
    return;
  }

  pa_volume_ = (pa_volume_t)std::lround(volume_ * PA_VOLUME_NORM);
  pa_cvolume cvolume;
  pa_cvolume_set(&cvolume, sample_spec_.channels, pa_volume_);
  auto op = pa_context_set_sink_input_volume(
      context_, pa_stream_get_index(stream_), &cvolume, SetVolumeCallback,
      this);
  if (op) {
    pending_volume_sets_++;
    pa_operation_unref(op);
  }
}

// Must be called with the mainloop lock held. Waits until a context or
// stream is ready, or has failed. Doesn't need a timeout: libpulse fails the
// connection itself if the server stops responding. Woken by the state
// callbacks.
template <typename T> bool PcmPlayer::WaitUntilReady(T *object) {
  for (;;) {
    switch (readiness(object)) {
    case Readiness::kReady:
      return true;
    case Readiness::kFailed:
      return false;
    case Readiness::kPending:
      pa_threaded_mainloop_wait(mainloop_);
    }
  }
}

// Must be called with the mainloop lock held. Takes ownership of op.
bool PcmPlayer::WaitForOperation(pa_operation *op) {
  if (!op) {
    return false;
  }

  // Not every operation has a callback that signals (e.g. pa_context_subscribe
  // without one), so wake on any state change of the operation itself.
  pa_operation_set_state_callback(op, OperationStateCallback, this);
  while (pa_operation_get_state(op) == PA_OPERATION_RUNNING) {
    pa_threaded_mainloop_wait(mainloop_);
  }

  const bool done = pa_operation_get_state(op) == PA_OPERATION_DONE;
  pa_operation_set_state_callback(op, nullptr, nullptr);
  pa_operation_unref(op);
  return done;
}

std::unexpected<std::string> PcmPlayer::ContextError(const char *name) {
  return std::unexpected(std::format("Error calling {}: {}", name,
                                     pa_strerror(pa_context_errno(context_))));
}

// Exits when tearing down. When the stream fails, pauses and waits to
// reconnect, see PauseAfterFailureLocked.
void PcmPlayer::ThreadMainLoop() {
  const size_t frame_size = pa_frame_size(&sample_spec_);

  pa_threaded_mainloop_lock(mainloop_);
  while (play_state_ != kExiting) {
    if (!stream_) {
      // Dropped after a failure. Woken by set_play_state.
      if (play_state_ != kPlaying) {
        pa_threaded_mainloop_wait(mainloop_);
      } else if (!ReconnectLocked()) {
        PauseAfterFailureLocked();
      }
      continue;
    }

    if (!PA_STREAM_IS_GOOD(pa_stream_get_state(stream_))) {
      PauseAfterFailureLocked();
      continue;
    }

    const size_t writable = pa_stream_writable_size(stream_);
    if (writable == (size_t)-1) {
      PauseAfterFailureLocked();
      continue;
    }

    // Woken by the write callback when the server wants more data, by play
    // state changes and by replies
    if (play_state_ != kPlaying) {
      pa_threaded_mainloop_wait(mainloop_);
      continue;
    }

    if (samples_) {
      // Fits, since nothing has been written since the request. After a
      // reconnect the server accepts it anyway.
      if (pa_stream_write(stream_, samples_->data(), samples_->size(), nullptr,
                          0, PA_SEEK_RELATIVE) < 0) {
        PauseAfterFailureLocked();
        continue;
      }
      samples_.reset();
      continue;
    }

    if (request_pending_ || writable < min_request_bytes_) {
      pa_threaded_mainloop_wait(mainloop_);
      continue;
    }

    if (delay_request_) {
      // The last reply had nothing usable. Don't hammer the Dart side.
      delay_request_ = false;
      const auto retry_delay = std::chrono::microseconds(
          pa_bytes_to_usec(min_request_bytes_, &sample_spec_));
      pa_threaded_mainloop_unlock(mainloop_);
      std::this_thread::sleep_for(retry_delay);
      pa_threaded_mainloop_lock(mainloop_);
      continue;
    }

    request_pending_ = true;
    requested_frames_ = (uint32_t)(writable / frame_size);
    sample_callback_(requested_frames_);
  }
  pa_threaded_mainloop_unlock(mainloop_);
}

// Runs on the caller's thread with the reply to the outstanding request, or
// nullptr if it failed
void PcmPlayer::OnSamples(ByteVectorPtr samples) {
  if (!mainloop_) {
    return;
  }

  pa_threaded_mainloop_lock(mainloop_);
  if (request_pending_) {
    request_pending_ = false;
    // Only whole frames, and no more than requested
    const size_t frame_size = pa_frame_size(&sample_spec_);
    if (samples) {
      const size_t bytes =
          std::min(samples->size(), requested_frames_ * frame_size);
      samples->resize(bytes - bytes % frame_size);
    }
    if (play_state_ != kPlaying) {
      // Dropped, see the class comment
    } else if (samples && !samples->empty()) {
      samples_ = std::move(samples);
    } else {
      delay_request_ = true;
    }
    pa_threaded_mainloop_signal(mainloop_, 0);
  }
  pa_threaded_mainloop_unlock(mainloop_);
}

void PcmPlayer::OperationStateCallback(pa_operation *, void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  pa_threaded_mainloop_signal(self->mainloop_, 0);
}

void PcmPlayer::ContextStateCallback(pa_context *, void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  pa_threaded_mainloop_signal(self->mainloop_, 0);
}

void PcmPlayer::StreamStateCallback(pa_stream *, void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  pa_threaded_mainloop_signal(self->mainloop_, 0);
}

void PcmPlayer::StreamWriteCallback(pa_stream *, size_t, void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  pa_threaded_mainloop_signal(self->mainloop_, 0);
}

void PcmPlayer::ServerInfoCallback(pa_context *, const pa_server_info *info,
                                   void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  if (info) {
    self->sample_spec_ = info->sample_spec;
  }
  pa_threaded_mainloop_signal(self->mainloop_, 0);
}

void PcmPlayer::SubscribeCallback(pa_context *c,
                                  pa_subscription_event_type_t t, uint32_t idx,
                                  void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  if ((t & PA_SUBSCRIPTION_EVENT_FACILITY_MASK) !=
          PA_SUBSCRIPTION_EVENT_SINK_INPUT ||
      (t & PA_SUBSCRIPTION_EVENT_TYPE_MASK) != PA_SUBSCRIPTION_EVENT_CHANGE) {
    return;
  }
  if (!self->stream_ || idx != pa_stream_get_index(self->stream_)) {
    return;
  }

  unref_operation(
      pa_context_get_sink_input_info(c, idx, SinkInputInfoCallback, self));
}

void PcmPlayer::SinkInputInfoCallback(pa_context *, const pa_sink_input_info *i,
                                      int eol, void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  if (eol != 0 || !i) {
    pa_threaded_mainloop_signal(self->mainloop_, 0);
    return;
  }

  // Replies arrive in request order. While one of our own volume changes is
  // in flight, this info may predate it; once none are pending, the info
  // includes all of them, so any difference must come from someone else.
  // This plays the role of the event context GUID on Windows.
  if (self->pending_volume_sets_ > 0) {
    return;
  }

  const pa_volume_t v = pa_cvolume_max(&i->volume);
  if (v == self->pa_volume_) {
    return;
  }

  self->pa_volume_ = v;
  // The mixer allows boosting above 100%, which the API can't represent
  self->volume_ = std::min(1.0f, (float)v / PA_VOLUME_NORM);
  if (self->notify_volume_changes_) {
    self->volume_callback_(self->volume_);
  }
}

void PcmPlayer::SetVolumeCallback(pa_context *, int, void *userdata) {
  auto self = static_cast<PcmPlayer *>(userdata);
  self->pending_volume_sets_--;
}

} // namespace flutter_pcm
