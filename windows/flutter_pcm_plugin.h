#pragma once

#include "pcm_player.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

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

  void CallSampleCallback(uint32_t max_samples);
  void CallVolumeCallback(float volume);
  void CallPlayingCallback(bool playing);

private:
  flutter::PluginRegistrarWindows *registrar_;
  int window_proc_id_;
  flutter::MethodChannel<FlutterValue> channel_;
  HWND active_window_;

  std::mutex invocation_mutex_;
  std::vector<FlutterMethodInvocation> invocation_queue_;
  void ProcessMethodInvocations();

  PcmPlayer pcm_player_;

  // Expires when the plugin is destroyed
  std::shared_ptr<int> alive_ = std::make_shared<int>();
};

} // namespace flutter_pcm
