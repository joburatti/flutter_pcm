#include "flutter_pcm_plugin.h"

#include "magic_enum.h"

#include <flutter/method_result_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <string_view>

#define WM_PROCESS_INVOCATIONS 0x1999

namespace flutter_pcm {

// Using roll-your-own hash here as std::hash does not always want to be
// constexpr
constexpr uint64_t hash(std::string_view str) {
  uint64_t hash = 0;
  for (char c : str) {
    hash = (hash * 131) + c;
  }
  return hash;
}

FlutterPcmPlugin::FlutterPcmPlugin(flutter::PluginRegistrarWindows *registrar)
    : registrar_(registrar),
      channel_(registrar->messenger(), "flutter_pcm",
               &flutter::StandardMethodCodec::GetInstance()),
      pcm_player_(
          [this](auto n) { CallSampleCallback(n); },
          [this](auto f) { CallVolumeCallback(f); },
          [this](auto p) { CallPlayingCallback(p); }),
      top_level_window_(nullptr) {
  channel_.SetMethodCallHandler([this](const auto &call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND h, UINT msg, WPARAM w, LPARAM l) -> std::optional<LRESULT> {
        switch (msg) {
        case WM_PROCESS_INVOCATIONS:
          ProcessMethodInvocations();
          return 0;
        default:
          return std::nullopt;
        }
      });
}

FlutterPcmPlugin::~FlutterPcmPlugin() {
  // Messages posted while pcm_player_ is torn down must not reach this
  // object
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
}

void FlutterPcmPlugin::HandleMethodCall(const FlutterCall &method_call,
                                        std::unique_ptr<FlutterResult> result) {
  switch (hash(method_call.method_name())) {
  case hash("setup"):
    // Our window proc delegate runs in the top-level window that hosts the
    // implicit view (id 0). GetActiveWindow() would depend on focus.
    if (auto view = registrar_->GetViewById(0)) {
      top_level_window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
    }
    if (!top_level_window_) {
      result->Error("no_window", "No top-level window to post messages to");
      break;
    }
    if (auto setup_res = pcm_player_.Setup(); setup_res.has_value()) {
      auto audio_format = setup_res.value();
      std::string sample_format(
          magic_enum::enum_name(audio_format.sample_format));
      result->Success(
          flutter::EncodableMap{{"frequency", audio_format.frequency},
                                {"channels", audio_format.channels},
                                {"sampleFormat", sample_format}});
    } else {
      result->Error(setup_res.error());
    }
    break;
  case hash("setPlaying"): {
    auto p = std::get<bool>(*method_call.arguments());
    pcm_player_.set_play_state(p ? PcmPlayer::kPlaying : PcmPlayer::kPaused);
    result->Success(FlutterValue());
    break;
  }
  case hash("setVolume"): {
    auto v = std::get<double>(*method_call.arguments());
    pcm_player_.set_volume((float)v);
    result->Success(FlutterValue());
    break;
  }
  case hash("getVolume"):
    result->Success(FlutterValue(pcm_player_.get_volume()));
    break;
  default:
    result->NotImplemented();
  }
}

void FlutterPcmPlugin::CallSampleCallback(uint32_t max_samples) {
  // Replies run on the platform thread, like the destructor, so checking
  // the token is enough to know the plugin still exists
  auto deliver = [this, alive = std::weak_ptr<int>(alive_)](
                     ByteVectorPtr samples) {
    if (!alive.expired()) {
      pcm_player_.OnSamples(std::move(samples));
    }
  };

  const std::lock_guard<std::mutex> lock(invocation_mutex_);
  invocation_queue_.emplace_back(FlutterMethodInvocation(
      {"getSamples", std::make_unique<FlutterValue>(max_samples),
       std::make_unique<flutter::MethodResultFunctions<>>(
           [deliver](const FlutterValue *result) {
             auto bytes =
                 result ? std::get_if<std::vector<uint8_t>>(result) : nullptr;
             deliver(bytes ? std::make_unique<std::vector<uint8_t>>(*bytes)
                           : nullptr);
           },
           [deliver](auto ec, auto em, auto ed) { deliver(nullptr); },
           [deliver]() { deliver(nullptr); })}));

  PostMessage(top_level_window_, WM_PROCESS_INVOCATIONS, 0, 0);
}

void FlutterPcmPlugin::CallVolumeCallback(float volume) {
  const std::lock_guard<std::mutex> lock(invocation_mutex_);
  invocation_queue_.emplace_back(FlutterMethodInvocation{
      "onVolumeChanged", std::make_unique<FlutterValue>(volume)});
  PostMessage(top_level_window_, WM_PROCESS_INVOCATIONS, 0, 0);
}

void FlutterPcmPlugin::CallPlayingCallback(bool playing) {
  const std::lock_guard<std::mutex> lock(invocation_mutex_);
  invocation_queue_.emplace_back(FlutterMethodInvocation{
      "onPlayingChanged", std::make_unique<FlutterValue>(playing)});
  PostMessage(top_level_window_, WM_PROCESS_INVOCATIONS, 0, 0);
}

void FlutterPcmPlugin::ProcessMethodInvocations() {
  const std::lock_guard<std::mutex> lock(invocation_mutex_);

  for (auto &invocation : invocation_queue_) {
    channel_.InvokeMethod(invocation.method, std::move(invocation.arguments),
                          std::move(invocation.result));
  }
  invocation_queue_.clear();
}
} // namespace flutter_pcm
