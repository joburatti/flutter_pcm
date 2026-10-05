import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  AudioFormat? _audioFormat;
  bool _playing = false;
  double _volume = 1.0;
  int _sampleOffset = 0;

  Uint8List _sampleCallback(int maxFrames) {
    final format = _audioFormat;
    if (format == null) {
      return Uint8List(0);
    }

    // uint8 is unsigned, but uint16 and uint32 are signed on every backend.
    final (
      int bytes,
      void Function(ByteData, int, double) write,
    ) = switch (format.sampleFormat) {
      SampleFormat.float32 => (4, (d, o, v) => d.setFloat32(o, v, Endian.host)),
      SampleFormat.float64 => (8, (d, o, v) => d.setFloat64(o, v, Endian.host)),
      SampleFormat.uint8 => (
        1,
        (d, o, v) => d.setUint8(o, (128 + v * 127).round()),
      ),
      SampleFormat.uint16 => (
        2,
        (d, o, v) => d.setInt16(o, (v * 32767).round(), Endian.host),
      ),
      SampleFormat.uint32 => (
        4,
        (d, o, v) => d.setInt32(o, (v * 2147483647).round(), Endian.host),
      ),
    };

    final channels = format.channels;
    final data = ByteData(maxFrames * channels * bytes);
    for (int frame = 0; frame < maxFrames; frame++) {
      final v = sin((_sampleOffset + frame) / 30);
      for (int c = 0; c < channels; c++) {
        write(data, (frame * channels + c) * bytes, v);
      }
    }
    _sampleOffset += maxFrames;
    return data.buffer.asUint8List();
  }

  void _togglePlaying() {
    setState(() {
      _playing = !_playing;
      FlutterPcm.setPlaying(_playing);
    });
  }

  void _volumeSliderChanged(double value) {
    setState(() {
      _volume = value;
      FlutterPcm.setVolume(_volume);
    });
  }

  void _onPcmSessionVolumeChanged(double value) {
    setState(() {
      _volume = value;
    });
  }

  @override
  void initState() {
    super.initState();
    FlutterPcm.setup(
      _sampleCallback,
      volumeCallback: _onPcmSessionVolumeChanged,
    ).then((result) async {
      final v = await FlutterPcm.getVolume();
      setState(() {
        _audioFormat = result;
        _volume = v;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('PCM example')),
        body: Center(
          child: Column(
            children: [
              FloatingActionButton(
                onPressed: _togglePlaying,
                child: Text(_playing ? "Pause" : "Play"),
              ),
              Slider(value: _volume, onChanged: _volumeSliderChanged),
              Text('Frequency: ${_audioFormat?.frequency}\n'),
              Text('Channels: ${_audioFormat?.channels}\n'),
              Text('Format: ${_audioFormat?.sampleFormat.name}\n'),
            ],
          ),
        ),
      ),
    );
  }
}
