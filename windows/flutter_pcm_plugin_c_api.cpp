#include "include/flutter_pcm/flutter_pcm_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_pcm_plugin.h"

void FlutterPcmPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  const auto win_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);

  auto plugin = std::make_unique<flutter_pcm::FlutterPcmPlugin>(win_registrar);
  win_registrar->AddPlugin(std::move(plugin));
}
