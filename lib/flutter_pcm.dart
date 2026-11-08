import 'package:flutter/services.dart';

enum SampleFormat { float32, float64, uint8, uint16, uint32 }

class AudioFormat {
  final int frequency;
  final int channels;
  final SampleFormat sampleFormat;

  AudioFormat(this.frequency, this.channels, this.sampleFormat);
}

typedef SampleCallback = Uint8List Function(int maxSamples);

/// Reports a volume change made outside the app, in the system mixer
/// (Windows and Linux only). See [FlutterPcm.setVolume] for the scale.
typedef VolumeCallback = void Function(double volume);

/// Reports playback that the system paused or resumed on its own, and a
/// [FlutterPcm.setPlaying] call that was refused.
///
/// On every platform, playback pauses when the audio device or server fails
/// (for example the output device was unplugged on Windows, or the sound
/// server restarted on Linux). The next `setPlaying(true)` reopens it with
/// the format returned by [FlutterPcm.setup], so the sample callback can
/// keep producing that format. On Android, audio focus changes and unplugged
/// headphones also pause, and a transient focus loss resumes by itself.
typedef PlayingCallback = void Function(bool playing);

class FlutterPcm {
  static final _methodChannel = _createChannel();
  static SampleCallback? _sampleCallback;
  static VolumeCallback? _volumeCallback;
  static PlayingCallback? _playingCallback;

  /// Opens the audio device and returns the format that [sampleCallback]
  /// must produce.
  ///
  /// Throws a [PlatformException] if it fails. Its code is `already_set_up`
  /// if setup has already succeeded, and `setup_failed` otherwise; then
  /// setup can be called again. A failed call keeps the previous callbacks.
  static Future<AudioFormat> setup(
    SampleCallback sampleCallback, {
    VolumeCallback? volumeCallback,
    PlayingCallback? playingCallback,
  }) async {
    final previousSample = _sampleCallback;
    final previousVolume = _volumeCallback;
    final previousPlaying = _playingCallback;
    _sampleCallback = sampleCallback;
    _volumeCallback = volumeCallback;
    _playingCallback = playingCallback;
    final Map<String, dynamic> res;
    try {
      res = (await _methodChannel.invokeMapMethod<String, dynamic>('setup'))!;
    } catch (_) {
      _sampleCallback = previousSample;
      _volumeCallback = previousVolume;
      _playingCallback = previousPlaying;
      rethrow;
    }

    return AudioFormat(
      res["frequency"],
      res["channels"],
      SampleFormat.values.byName(res["sampleFormat"]),
    );
  }

  /// Sets the playback volume, a linear gain (amplitude) from 0 to 1: 0.5 is
  /// about -6 dB. Values outside that range are clamped, and NaN is ignored.
  ///
  /// On Windows and Linux this is the app's volume in the system mixer,
  /// which the user can change too (reported through the volume callback)
  /// and which the system remembers between runs. Linux mixers show a cubic
  /// scale, so 0.5 shows as 79%. Android and iOS/macOS have no per-app
  /// mixer volume; the volume is a gain the player applies, and starts at 1
  /// on every launch.
  ///
  /// It can be called before [setup]. Then [setup] applies it, replacing the
  /// volume the system remembered.
  static void setVolume(double volume) {
    _methodChannel.invokeMethod("setVolume", volume);
  }

  /// Returns the playback volume, on the same scale as [setVolume].
  ///
  /// Before [setup], it is 1 unless [setVolume] was called. After [setup],
  /// on Windows and Linux, it is the volume the system remembered, unless
  /// [setVolume] was called before [setup].
  static Future<double> getVolume() async {
    return await _methodChannel.invokeMethod<double>("getVolume") ?? 1;
  }

  static Future<void> setPlaying(bool p) async {
    return _methodChannel.invokeMethod<void>("setPlaying", p);
  }

  static Future<dynamic> _channelMethodCallHandler(MethodCall call) async {
    switch (call.method) {
      case "getSamples":
        int sampleCount = call.arguments;
        return _sampleCallback!(sampleCount);
      case "onVolumeChanged":
        if (_volumeCallback != null) {
          _volumeCallback!(call.arguments);
        }
      case "onPlayingChanged":
        if (_playingCallback != null) {
          _playingCallback!(call.arguments);
        }
      default:
        throw MissingPluginException();
    }
  }

  static MethodChannel _createChannel() {
    final channel = MethodChannel('flutter_pcm');
    channel.setMethodCallHandler(_channelMethodCallHandler);
    return channel;
  }
}
