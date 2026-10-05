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

constexpr uint64_t operator"" _hash(const char *str, size_t len) {
  return hash(std::string_view(str, len));
}

FlutterPcmPlugin::FlutterPcmPlugin(flutter::PluginRegistrarWindows *registrar)
    : channel_(registrar->messenger(), "flutter_pcm",
               &flutter::StandardMethodCodec::GetInstance()),
      pcm_player_([this](auto n) { return CallSampleCallback(n); },
                  [this](auto f) { CallVolumeCallback(f); }),
      active_window_(nullptr) {
  channel_.SetMethodCallHandler([this](const auto &call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  registrar->RegisterTopLevelWindowProcDelegate(
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

FlutterPcmPlugin::~FlutterPcmPlugin() {}

void FlutterPcmPlugin::HandleMethodCall(const FlutterCall &method_call,
                                        std::unique_ptr<FlutterResult> result) {
  switch (hash(method_call.method_name())) {
  case hash("setup"):
    active_window_ = GetActiveWindow();
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

std::future<std::unique_ptr<std::vector<uint8_t>>>
FlutterPcmPlugin::CallSampleCallback(uint32_t max_samples) {
  auto promise =
      std::make_shared<std::promise<std::unique_ptr<std::vector<uint8_t>>>>();

  const std::lock_guard<std::mutex> lock(invocation_mutex_);
  invocation_queue_.emplace_back(FlutterMethodInvocation(
      {"getSamples", std::make_unique<FlutterValue>(max_samples),
       std::make_unique<flutter::MethodResultFunctions<>>(
           [promise](auto result) {
             // move:ing result to the new list looks iffy but works here as
             // result is about to be destroyed anyway
             promise->set_value(std::make_unique<std::vector<uint8_t>>(
                 std::get<std::vector<uint8_t>>(std::move(*result))));
           },
           [promise](auto ec, auto em, auto ed) {
             promise->set_exception(
                 std::make_exception_ptr(std::runtime_error("")));
           },
           [promise]() {
             promise->set_exception(
                 std::make_exception_ptr(std::runtime_error("")));
           })}));

  PostMessage(active_window_, WM_PROCESS_INVOCATIONS, 0, 0);
  return promise->get_future();
}

void FlutterPcmPlugin::CallVolumeCallback(float volume) {
  const std::lock_guard<std::mutex> lock(invocation_mutex_);
  invocation_queue_.emplace_back(FlutterMethodInvocation{
      "onVolumeChanged", std::make_unique<FlutterValue>(volume)});
  PostMessage(active_window_, WM_PROCESS_INVOCATIONS, 0, 0);
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
