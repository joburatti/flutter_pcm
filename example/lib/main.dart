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
  int _sample_offset = 0;

  Uint8List _sampleCallback(int maxSamples) {
    // Assume 2 channels and float32 format
    final samples = List<double>.generate(
      2 * maxSamples,
      (int i) => sin((_sample_offset + i ~/ 2) / 30),
      growable: false,
    );
    _sample_offset += maxSamples;
    return Float32List.fromList(samples).buffer.asUint8List();
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
