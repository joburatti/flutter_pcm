import 'package:flutter/services.dart';

enum SampleFormat { float32, float64, uint8, uint16, uint32 }

class AudioFormat {
  final int frequency;
  final int channels;
  final SampleFormat sampleFormat;

  AudioFormat(this.frequency, this.channels, this.sampleFormat);
}

typedef SampleCallback = Uint8List Function(int maxSamples);
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

  static Future<AudioFormat?> setup(
    SampleCallback sampleCallback, {
    VolumeCallback? volumeCallback,
    PlayingCallback? playingCallback,
  }) async {
    _sampleCallback = sampleCallback;
    _volumeCallback = volumeCallback;
    _playingCallback = playingCallback;
    final res = await _methodChannel.invokeMapMethod<String, dynamic>('setup');

    if (res == null) {
      return null;
    }

    return AudioFormat(
      res["frequency"],
      res["channels"],
      SampleFormat.values.byName(res["sampleFormat"]),
    );
  }

  static void setVolume(double volume) {
    _methodChannel.invokeMethod("setVolume", volume);
  }

  static Future<double> getVolume() async {
    return await _methodChannel.invokeMethod<double>("getVolume") ?? 0;
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
