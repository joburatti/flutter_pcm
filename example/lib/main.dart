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

  Float32List _sampleCallback(int maxFrames) {
    final format = _audioFormat;
    if (format == null) {
      return Float32List(0);
    }

    final channels = format.channels;
    final samples = Float32List(maxFrames * channels);
    for (int frame = 0; frame < maxFrames; frame++) {
      final v = sin((_sampleOffset + frame) / 30);
      for (int c = 0; c < channels; c++) {
        samples[frame * channels + c] = v;
      }
    }
    _sampleOffset += maxFrames;
    return samples;
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

  void _onPcmPlayingChanged(bool playing) {
    setState(() {
      _playing = playing;
    });
  }

  @override
  void initState() {
    super.initState();
    FlutterPcm.setup(
      _sampleCallback,
      volumeCallback: _onPcmSessionVolumeChanged,
      playingCallback: _onPcmPlayingChanged,
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
            ],
          ),
        ),
      ),
    );
  }
}
