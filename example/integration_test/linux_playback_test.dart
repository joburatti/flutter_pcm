// Linux-only integration test: plays silence through PulseAudio and checks
// the stream from the outside with pactl.
//
// Run with: flutter test integration_test/linux_playback_test.dart -d linux

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

/// Finds this process' sink input (our playback stream) via pactl.
Future<Map<String, dynamic>?> findSinkInput() async {
  final res = await Process.run('pactl', ['-f', 'json', 'list', 'sink-inputs']);
  final inputs = jsonDecode(res.stdout as String) as List<dynamic>;
  for (final input in inputs.cast<Map<String, dynamic>>()) {
    final props = input['properties'] as Map<String, dynamic>;
    if (props['application.process.id'] == '$pid') {
      return input;
    }
  }
  return null;
}

/// Volume of the first channel in percent, as shown by the system mixer.
int volumePercent(Map<String, dynamic> sinkInput) {
  final volume = sinkInput['volume'] as Map<String, dynamic>;
  final first = volume.values.first as Map<String, dynamic>;
  return int.parse((first['value_percent'] as String).replaceAll('%', ''));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause and volume', (WidgetTester tester) async {
    var framesRequested = 0;
    final externalVolumes = <double>[];

    late AudioFormat format;
    final result = await FlutterPcm.setup((int maxFrames) {
      framesRequested += maxFrames;
      return Uint8List(maxFrames * format.channels * 4);
    }, volumeCallback: externalVolumes.add);

    expect(result, isNotNull);
    format = result!;
    expect(format.sampleFormat, SampleFormat.float32);
    expect(format.channels, greaterThan(0));
    expect(format.frequency, greaterThan(0));

    // The stream exists but starts corked
    final sinkInput = await findSinkInput();
    expect(sinkInput, isNotNull);
    expect(sinkInput!['corked'], isTrue);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(framesRequested, 0);

    // Playing pulls samples at roughly the sample rate
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(seconds: 2));
    final playedFrames = framesRequested;
    expect((await findSinkInput())!['corked'], isFalse);
    expect(playedFrames, greaterThan(format.frequency * 1.5));
    expect(playedFrames, lessThan(format.frequency * 2.5));

    // Our own volume changes reach the mixer without echoing back
    FlutterPcm.setVolume(0.5);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(volumePercent((await findSinkInput())!), 50);
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    expect(externalVolumes, isEmpty);

    // Dragging a slider sends many changes in a row; none may echo back
    for (var v = 0.0; v <= 1.0; v += 0.02) {
      FlutterPcm.setVolume(v);
      await Future.delayed(const Duration(milliseconds: 2));
    }
    FlutterPcm.setVolume(0.5);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isEmpty);
    expect(volumePercent((await findSinkInput())!), 50);

    // Mixer changes are reported back
    await Process.run('pactl', [
      'set-sink-input-volume',
      '${sinkInput['index']}',
      '30%',
    ]);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isNotEmpty);
    expect(externalVolumes.last, closeTo(0.3, 0.01));
    expect(await FlutterPcm.getVolume(), closeTo(0.3, 0.01));

    // Pausing corks the stream and stops pulling samples
    await FlutterPcm.setPlaying(false);
    await Future.delayed(const Duration(milliseconds: 300));
    final pausedFrames = framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, pausedFrames);
    expect((await findSinkInput())!['corked'], isTrue);

    // And resumes
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, greaterThan(pausedFrames));
    await FlutterPcm.setPlaying(false);
  });
}
