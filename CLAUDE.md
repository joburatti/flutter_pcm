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
cd example && flutter test integration_test/windows_playback_test.dart -d windows   # needs an audio device
cd example && flutter build linux --debug
cd example && flutter test integration_test/linux_playback_test.dart -d linux
cd example && flutter build apk --debug
cd example && flutter test integration_test/android_playback_test.dart -d emulator-5554
```

`linux_playback_test.dart` plays silence. It uses `pactl` to check that the stream is created, corked and uncorked, that our volume changes reach the mixer without echoing back, and that mixer changes are reported back. It finds our stream by matching `application.process.id`. It also restarts `pipewire`/`pipewire-pulse` with `systemctl --user` (briefly interrupting other audio) to check that a server failure pauses and reports, that playing while the server is down is refused, and that playing afterwards reconnects with the same format and volume.

`windows_playback_test.dart` checks the pull rate, pause and resume, a slow reply, and that our volume changes don't echo back. It doesn't cover mixer changes or device failure. To check Windows device failure by hand, play in the example app and unplug or disable the output device in Sound settings. The app should switch to paused, and pressing play should continue on the new default device.

`android_playback_test.dart` runs on the device, so it can't inspect the stream from outside. It checks the pull rate, pause and resume, and the volume getter. It also checks audio focus: a transient loss pauses and the regained focus resumes, pausing while waiting for focus cancels the resume, and a permanent loss pauses until the app plays again. To take focus away, it calls the `flutter_pcm_example/focus` channel in the example's `MainActivity`, which requests focus with its own listener; Android tracks focus per listener, so this competes with the player inside the same app. To check a real call by hand, play in the example app and simulate a call with `adb emu gsm call 5551234` and then `adb emu gsm cancel 5551234`. During the call, `adb shell dumpsys audio` should show our player `paused`, and afterwards `started`.

The example app has `windows/`, `linux/` and `android/` runners. To try the Darwin code, first run `flutter create --platforms=macos,ios .` in `example/`.

### CI
`.github/workflows/ci.yml` has one job per platform:
- **linux**: analyze, widget test, and `linux_playback_test.dart`. The runner has no session or sound card. The job starts a user systemd manager with `loginctl enable-linger`, so the test's `systemctl --user` restarts work, and runs PipeWire with a null sink defined in a config file, so the sink survives restarts. It uses `xvfb-run`. It builds with clang 19 through symlinks on `PATH`, because Flutter always uses plain `clang++`, and Ubuntu 24.04's clang 18 can't use `std::expected` from libstdc++ 14.
- **android**: builds the APK, then runs `android_playback_test.dart` on an API 35 emulator (KVM). Emulator audio stays enabled.
- **windows**: installs the VB-CABLE virtual sound card (`LABSN/sound-ci-helpers`), starts `Audiosrv`, and runs `windows_playback_test.dart`. The runner's MSVC builds with `/WX`, and newer versions warn about more than older ones.
- **darwin**: build only. It generates the `macos/` and `ios/` runners with `flutter create` and builds macOS and the iOS simulator.

The Flutter version is pinned in `FLUTTER_VERSION`.

## Architecture

### Dart API: `lib/flutter_pcm.dart`
The whole public API is the static class `FlutterPcm`, which talks over one `MethodChannel('flutter_pcm')`.

Dart → native calls:
- `setup` returns `{frequency, channels, sampleFormat}`. `sampleFormat` is the string name of a `SampleFormat` enum value.
- `setPlaying(bool)`
- `setVolume(double)`
- `getVolume`

Native → Dart calls (handled in `_channelMethodCallHandler`):
- `getSamples(int maxFrames)`: Dart must return a `Uint8List` of interleaved samples in the device format. At most one request is outstanding at a time. Native code never blocks on the reply and never gives up on it: a late reply is still played, unless it arrives while paused; then it may be dropped (a pause is a glitch anyway). So a reply always fits in one write, since nothing is written while a request is outstanding. The exception is a reply written to a device reopened after a failure, whose buffer may be smaller; what doesn't fit is dropped. An error or non-`Uint8List` reply counts as empty, and the next request comes after a short delay. A call to Dart is only really lost if its isolate goes away (hot restart); that isn't handled yet, and a second `setup()` currently fails. The argument counts **frames** (one sample per channel), although it is named "samples". Returning fewer bytes is allowed; native code writes `min(available, returned)` frames.
- `onVolumeChanged(double)`: the session volume was changed outside the app (for example in the Windows volume mixer).
- `onPlayingChanged(bool)`: the system paused or resumed playback on its own, or refused a `setPlaying(true)`. Every backend sends it when the audio device or server fails; Android also sends it for audio focus changes.

The `SampleFormat` enum names (`float32, float64, uint8, uint16, uint32`) must match **exactly** across Dart, C++ (`pcm_player.h`, serialized with `magic_enum::enum_name`) and Swift (`String` raw values). Native code may also send `unknown`, and Dart's `byName` would throw on it. The `uint*` names really stand for the device's integer PCM formats (on Darwin, `Int16` maps to `uint16`).

### Windows: `windows/`
- `flutter_pcm_plugin_c_api.cpp` is the registration entry point (`FlutterPcmPluginCApi` in pubspec).
- `FlutterPcmPlugin` (`flutter_pcm_plugin.{h,cpp}`) handles the method channel. Method names are dispatched with a constexpr string hash (`hash("setup")`).
  - **Threading**: Native → Dart messages must be sent on the platform thread (the engine logs an error in debug builds otherwise; only replies to Dart → native calls may come from any thread), and the plugin registrar has no way to post a task to it. The audio thread therefore calls `CallSampleCallback`, `CallVolumeCallback` and `CallPlayingCallback`, which queue a `FlutterMethodInvocation` under a mutex and `PostMessage(top_level_window_, WM_PROCESS_INVOCATIONS)`. A top-level WindowProc delegate drains the queue on the UI thread. The `getSamples` reply is handed to `PcmPlayer::OnSamples` on the platform thread, guarded by a `weak_ptr` token (`alive_`) in case the plugin is gone. The delegate is unregistered in the plugin destructor, before `pcm_player_` is torn down.
  - `top_level_window_` is captured during `setup` as the root ancestor (`GA_ROOT`) of the implicit view's HWND (`GetViewById(0)`), because the delegate only runs in the top-level window's WindowProc. `setup` fails if there is no implicit view. (It used to be `GetActiveWindow()`, which returned null when the app had no focus, so no message reached Dart.)
- `PcmPlayer` (`pcm_player.{h,cpp}`) owns a dedicated audio thread (`ThreadRunner`).
  - The thread opens the device in `OpenDevice` (COM objects held in a `Device` struct): the default render endpoint, the mix format, a 100 ms shared-mode buffer, and `IAudioSessionEvents` for volume and disconnect notifications.
  - It fulfills the setup promise with the `AudioFormat`, then loops in `ThreadMainLoop`.
  - The loop waits on a condition variable while paused. While playing, it sleeps until about half the buffer is free, then writes the last reply in full, or else requests frames from Dart and waits on the condition variable for `OnSamples`.
  - If a WASAPI call fails (typically `AUDCLNT_E_DEVICE_INVALIDATED`) or the session is disconnected, the thread releases the device, pauses and sends `onPlayingChanged(false)` if it was playing, then waits without a device (the thread does not exit). When `setPlaying(true)` wakes it, it opens the current default endpoint with the original `WAVEFORMATEX`, using `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` so that Windows converts, and re-applies the volume. If that fails, it pauses and sends `onPlayingChanged(false)` again. Because the thread reopens the device, `setPlaying` returns before the outcome is known. WASAPI does not follow default-device changes by itself.
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
  - `audio_thread_` waits until `writable >= minreq`, then writes the last reply in full, or else requests `writable / frame_size` frames from Dart and waits on the mainloop for `OnSamples`. The plugin's `SampleRequest` holds a ref on the plugin, so the reply can reach the player.
  - If the stream or context fails (typically the server restarted), the audio thread drops the context and stream, pauses and sends `onPlayingChanged(false)` if it was playing, then waits with `stream_` null (the thread does not exit). The mainloop survives. When `setPlaying(true)` wakes it, the thread reconnects with the stored `sample_spec_` (the server converts), resets `pending_volume_sets_` and re-applies the volume. If that fails, it pauses and sends `onPlayingChanged(false)` again. `set_play_state` only corks a stream that is ready; a stream that connects later catches up with the play state. Removing a sink is not a failure; the server moves the stream.
  - Volume is the sink-input volume, mapped linearly to `pa_volume_t` (0..`PA_VOLUME_NORM`), so it matches the percentage shown in the mixer.
  - External changes arrive through a sink-input subscription. Echoes of our own changes are suppressed by ignoring sink-input info while `pending_volume_sets_ > 0`; this works because replies arrive in request order.
- Builds as C++23 (`target_compile_features` in `linux/CMakeLists.txt`), with `-Wall -Werror` from the runner's `apply_standard_settings`. Links `libpulse` via pkg-config; build hosts need `libpulse-dev`.

### Android: `android/`
- Kotlin with no JNI or NDK; minSdk 24. Package and namespace `com.example.flutter_pcm`.
- `FlutterPcmPlugin.kt` handles the method channel. The audio thread's `getSamples` requests are posted to the main looper, and the reply is handed to `PcmPlayer.onSamples`.
- `PcmPlayer.kt` uses an `AudioTrack` in stream mode. The format is fixed at float32 stereo at the device's native rate (`PROPERTY_OUTPUT_SAMPLE_RATE`), which is the mixer's fast path. The buffer is 100 ms.
  - The audio thread works out free space from `playbackHeadPosition` (an unsigned 32-bit value that wraps). Once half the buffer is free, it requests that many frames and writes them **non-blocking**, because a blocking write on a paused track would stall. Bytes that didn't fit (only possible on a rebuilt track) are logged and dropped. After an underrun (`underrunCount` went up), and after a pause, the track only starts once its buffer is full, so the thread then requests whatever is writable until it is.
  - Volume is a per-track gain (`AudioTrack.setVolume`). Android has no per-app mixer volume, so `onVolumeChanged` is never sent.
  - `setPlaying(true)` requests `AUDIOFOCUS_GAIN`. If focus is denied, playback stays paused and `onPlayingChanged(false)` is sent. A transient loss pauses playback, and regaining focus resumes it; each change is reported. A permanent loss, or `ACTION_AUDIO_BECOMING_NOISY` (headphones unplugged), pauses until the app plays again, including when it happens while playback waits for a transient loss to end. Besides `PAUSED`/`PLAYING`/`EXITING`, `PlayState` has `PENDING` ("start as soon as possible"). It covers `setPlaying(true)` before `setup()` and waiting for a transient focus loss to end; the audio thread treats it as paused. Ducking is left to the system (Android 8+), except below 8, where the player ducks itself.
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

There is no Swift toolchain on this machine; CI builds both macOS and iOS. `outputProvider = fillSpeakerBuffer` captures `self` strongly, so `deinit` does not run while the audio unit exists.

The podspec links `CoreAudio`, with deployment targets iOS 15 and macOS 12.

## Known issues / gotchas
- There is no `teardown` in the Dart API. Native players are torn down only when the plugin is destroyed.
- Despite the names, `uint16`/`uint32` are **signed** integer PCM on every backend. Only `uint8` is unsigned (offset 128). On Windows, 24-bit integer mix formats come back as `unknown`.
