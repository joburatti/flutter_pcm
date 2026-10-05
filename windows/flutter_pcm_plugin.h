#pragma once

#include "pcm_player.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <future>
#include <memory>
#include <vector>

namespace flutter_pcm {
using FlutterValue = flutter::EncodableValue;
using FlutterCall = flutter::MethodCall<FlutterValue>;
using FlutterResult = flutter::MethodResult<FlutterValue>;

struct FlutterMethodInvocation {
  std::string method;
  std::unique_ptr<FlutterValue> arguments;
  std::unique_ptr<FlutterResult> result;
};

class FlutterPcmPlugin : public flutter::Plugin {
public:
  FlutterPcmPlugin(flutter::PluginRegistrarWindows *registrar);

  virtual ~FlutterPcmPlugin();

  FlutterPcmPlugin(const FlutterPcmPlugin &) = delete;
  FlutterPcmPlugin &operator=(const FlutterPcmPlugin &) = delete;

  void HandleMethodCall(const FlutterCall &method_call,
                        std::unique_ptr<FlutterResult> result);

  std::future<ByteVectorPtr> CallSampleCallback(uint32_t max_samples);
  void CallVolumeCallback(float volume);

private:
  flutter::MethodChannel<FlutterValue> channel_;
  HWND active_window_;

  std::mutex invocation_mutex_;
  std::vector<FlutterMethodInvocation> invocation_queue_;
  void ProcessMethodInvocations();

  PcmPlayer pcm_player_;
};

} // namespace flutter_pcm
