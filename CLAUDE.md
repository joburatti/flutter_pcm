# CLAUDE.md

This file guides Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`flutter_pcm` is a Flutter plugin that plays raw PCM audio. The app does not push audio. The native side pulls it: when the output device needs data, the native code calls back into Dart for a block of samples. The audio device decides the sample format, and `setup()` reports it to the caller. The Dart side must produce bytes in that format (no conversion or resampling happens).

Platform status:
- **Windows**: complete (WASAPI, shared mode).
- **Linux**: complete (PulseAudio client API; on this machine served by PipeWire through `pipewire-pulse`).
- **Android**: complete (`AudioTrack` in Kotlin, with audio focus handling).
- **iOS/macOS**: in progress, under `darwin/` with `sharedDarwinSource: true`. Only init and deinit exist so far (commit "step 1: init/deinit"). See "Darwin status" below.
- No web implementation.

## Commands

This machine is Linux with the Flutter SDK (`~/flurp/flutter`, linked into `~/.local/bin`) and the Android SDK (`~/Android/Sdk`, with an emulator), so Linux and Android builds and tests run here. Windows and Darwin builds need their own hosts.

```sh
flutter pub get                       # in repo root and/or example/
flutter analyze                       # lints: package:flutter_lints/flutter.yaml
cd example && flutter run -d windows  # run the demo app (sine wave + volume slider)
cd example && flutter test            # widget test (test/widget_test.dart)
cd example && flutter test integration_test -d windows   # needs a real audio device
cd example && flutter build linux --debug
cd example && flutter test integration_test/linux_playback_test.dart -d linux
cd example && flutter build apk --debug
cd example && flutter test integration_test/android_playback_test.dart -d emulator-5554
```

`linux_playback_test.dart` plays silence. It uses `pactl` to check that the stream is created, corked and uncorked, that our volume changes reach the mixer without echoing back, and that mixer changes are reported back. It finds our stream by matching `application.process.id`.

`android_playback_test.dart` runs on the device, so it can't inspect the stream from outside. It checks the pull rate, pause and resume, and the volume getter. To check audio focus by hand, play in the example app and simulate a call with `adb emu gsm call 5551234` and then `adb emu gsm cancel 5551234`. During the call, `adb shell dumpsys audio` should show our player `paused`, and afterwards `started`.

The example app has `windows/`, `linux/` and `android/` runners. To try the Darwin code, first run `flutter create --platforms=macos,ios .` in `example/`.

## Architecture

### Dart API: `lib/flutter_pcm.dart`
The whole public API is the static class `FlutterPcm`, which talks over one `MethodChannel('flutter_pcm')`.

Dart → native calls:
- `setup` returns `{frequency, channels, sampleFormat}`. `sampleFormat` is the string name of a `SampleFormat` enum value.
- `setPlaying(bool)`
- `setVolume(double)`
- `getVolume`

Native → Dart calls (handled in `_channelMethodCallHandler`):
- `getSamples(int maxFrames)`: Dart must return a `Uint8List` of interleaved samples in the device format. The argument counts **frames** (one sample per channel), although it is named "samples". Returning fewer bytes is allowed; native code writes `min(available, returned)` frames.
- `onVolumeChanged(double)`: the session volume was changed outside the app (for example in the Windows volume mixer).
- `onPlayingChanged(bool)`: the system paused or resumed playback on its own, or refused a `setPlaying(true)`. Only Android sends it.

The `SampleFormat` enum names (`float32, float64, uint8, uint16, uint32`) must match **exactly** across Dart, C++ (`pcm_player.h`, serialized with `magic_enum::enum_name`) and Swift (`String` raw values). Native code may also send `unknown`, and Dart's `byName` would throw on it. The `uint*` names really stand for the device's integer PCM formats (on Darwin, `Int16` maps to `uint16`).

### Windows: `windows/`
- `flutter_pcm_plugin_c_api.cpp` is the registration entry point (`FlutterPcmPluginCApi` in pubspec).
- `FlutterPcmPlugin` (`flutter_pcm_plugin.{h,cpp}`) handles the method channel. Method names are dispatched with a constexpr string hash (`hash("setup")`).
  - **Threading**: Flutter channel calls must happen on the platform thread. The audio thread therefore calls `CallSampleCallback` and `CallVolumeCallback`, which queue a `FlutterMethodInvocation` under a mutex and `PostMessage(active_window_, WM_PROCESS_INVOCATIONS)`. A top-level WindowProc delegate drains the queue on the UI thread. `CallSampleCallback` returns a `std::future` that is fulfilled by the Dart reply.
  - `active_window_` is captured with `GetActiveWindow()` during `setup`.
- `PcmPlayer` (`pcm_player.{h,cpp}`) owns a dedicated audio thread (`ThreadRunner`).
  - The thread sets up COM/WASAPI: the default render endpoint, the mix format, a 100 ms shared-mode buffer, and `IAudioSessionEvents` for volume notifications.
  - It fulfills the setup promise with the `AudioFormat`, then loops in `ThreadMainLoop`.
  - The loop waits on a condition variable while paused. While playing, it sleeps until about half the buffer is free, requests frames from Dart, and polls the future every 100 ms so it can still react to pause.
  - Volume set from the app uses `CONTEXT_GUID` as the event context, so the change does not echo back as `onVolumeChanged`.
  - `Teardown()` (called from the destructor) sets `kExiting` and joins the thread.
- Requires **C++23**: `std::expected`, `std::out_ptr`, `std::format`. `magic_enum.h` is vendored.
- Any new `.cpp`/`.h` file must be added to `PLUGIN_SOURCES` in `windows/CMakeLists.txt`.

### Linux: `linux/`
- `flutter_pcm_plugin.cc` is a GObject plugin using the `flutter_linux` C API.
  - Native → Dart calls are moved to the GTK main thread with `g_idle_add_full`. This replaces the Windows `PostMessage` queue. A `SampleRequest` carries a `std::promise` that the async `invoke_method` reply fulfills.
  - Each queued call holds its own ref on the `FlMethodChannel`. Plugin `dispose` deletes the `PcmPlayer` (joining its threads) before it releases the channel.
  - The channel's handler holds a ref on the plugin and the plugin holds the channel, the same pattern as the template and the official plugins. In practice the plugin lives until the process exits.
- `PcmPlayer` (`pcm_player.{h,cc}`) mirrors the Windows class, using `pa_threaded_mainloop`.
  - All PulseAudio state is guarded by the mainloop lock. `pa_threaded_mainloop_wait`/`signal` is the only condition variable; the write, state and operation callbacks and the setters all signal it.
  - The format is the server's default sample spec, falling back to float32 if it can't be expressed (the server converts). The buffer is 100 ms, with `minreq` at half.
  - The stream starts corked. `setPlaying` corks or uncorks it.
  - `audio_thread_` waits until `writable >= minreq`, then requests `writable / frame_size` frames from Dart with the mainloop unlocked, then writes them.
  - Volume is the sink-input volume, mapped linearly to `pa_volume_t` (0..`PA_VOLUME_NORM`), so it matches the percentage shown in the mixer.
  - External changes arrive through a sink-input subscription. Echoes of our own changes are suppressed by ignoring sink-input info while `pending_volume_sets_ > 0`; this works because replies arrive in request order.
- Builds as C++23 (`target_compile_features` in `linux/CMakeLists.txt`), with `-Wall -Werror` from the runner's `apply_standard_settings`. Links `libpulse` via pkg-config; build hosts need `libpulse-dev`.

### Android: `android/`
- Kotlin with no JNI or NDK; minSdk 24. Package and namespace `com.example.flutter_pcm`.
- `FlutterPcmPlugin.kt` handles the method channel. The audio thread's `getSamples` requests are posted to the main looper, and a `CompletableFuture` is completed by the Dart reply.
- `PcmPlayer.kt` uses an `AudioTrack` in stream mode. The format is fixed at float32 stereo at the device's native rate (`PROPERTY_OUTPUT_SAMPLE_RATE`), which is the mixer's fast path. The buffer is 100 ms.
  - The audio thread works out free space from `playbackHeadPosition` (an unsigned 32-bit value that wraps). Once half the buffer is free, it requests that many frames and writes them **non-blocking**, because a blocking write on a paused track would stall. Bytes that didn't fit are kept for the next write. A `getSamples` reply that takes over a second is given up on and requested again.
  - Volume is a per-track gain (`AudioTrack.setVolume`). Android has no per-app mixer volume, so `onVolumeChanged` is never sent.
  - `setPlaying(true)` requests `AUDIOFOCUS_GAIN`. If focus is denied, playback stays paused and `onPlayingChanged(false)` is sent. A transient loss pauses playback, and regaining focus resumes it; each change is reported. A permanent loss, or `ACTION_AUDIO_BECOMING_NOISY` (headphones unplugged), pauses until the app plays again, including when it happens while playback waits for a transient loss to end. Ducking is left to the system (Android 8+), except below 8, where the player ducks itself.
  - If a track write fails (for example `ERROR_DEAD_OBJECT`), playback pauses, `onPlayingChanged(false)` is sent and the track is dropped. The next `setPlaying(true)` rebuilds it with the format reported by `setup()`.
  - `release()` (from `onDetachedFromEngine`) sets the exiting state and joins the thread.

### Darwin status: `darwin/Classes/FlutterPcmPlugin.swift`
Current state:
- `setup` creates an `AUAudioUnit`: `DefaultOutput` on macOS, `RemoteIO` on iOS (with an `AVAudioSession` set to playback). It reads the format from `inputBusses[0]`, sets `outputProvider = fillSpeakerBuffer`, and starts the hardware.
- `fillSpeakerBuffer` is a stub. The `getSamples` round-trip is commented out.
- `setPlaying`, `setVolume` and `getVolume` return `nil`.

Remaining work:
- Make `fillSpeakerBuffer` work. The render callback is real-time, while channel calls must be dispatched to the main thread and are asynchronous. It cannot block on Dart, so it needs something like a ring buffer that a main-thread or worker producer fills by calling `getSamples`.
- Implement play/pause, volume, and `onVolumeChanged`.

The iOS branch has never been compiled (there is no Swift toolchain on this machine). `outputProvider = fillSpeakerBuffer` captures `self` strongly, so `deinit` does not run while the audio unit exists.

The podspec links `CoreAudio`, with deployment targets iOS 15 and macOS 12.

## Known issues / gotchas
- There is no `teardown` in the Dart API. Native players are torn down only when the plugin is destroyed.
- Despite the names, `uint16`/`uint32` are **signed** integer PCM on every backend. Only `uint8` is unsigned (offset 128). On Windows, 24-bit integer mix formats come back as `unknown`.
