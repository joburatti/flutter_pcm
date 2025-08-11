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

class FlutterPcm {
  static final _methodChannel = _createChannel();
  static SampleCallback? _sampleCallback;
  static VolumeCallback? _volumeCallback;

  static Future<AudioFormat?> setup(
    SampleCallback sampleCallback, {
    VolumeCallback? volumeCallback,
  }) async {
    _sampleCallback = sampleCallback;
    _volumeCallback = volumeCallback;
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
