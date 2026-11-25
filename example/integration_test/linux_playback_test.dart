// Linux-only integration test: plays silence through PulseAudio and checks
// the stream from the outside with pactl. It also restarts the user's
// PipeWire services, which briefly interrupts all other audio.
//
// Run with: flutter test integration_test/linux_playback_test.dart -d linux

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

import 'common.dart';

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

/// pactl's name for native-endian float32
String floatSampleFormat() =>
    Endian.host == Endian.little ? 'float32le' : 'float32be';

/// The mixer percentage for a volume. Our volume is a linear gain, and
/// PulseAudio's volume scale is cubic.
int mixerPercent(double volume) => (pow(volume, 1 / 3) * 100).round();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause, volume and server restart', (
    WidgetTester tester,
  ) async {
    final playback = Playback();
    final source = playback.source;
    final externalVolumes = playback.externalVolumes;
    final playingChanges = playback.playingChanges;

    await playback.setup();
    final format = playback.format;

    // The stream exists but starts corked, with the volume set before setup
    final sinkInput = await findSinkInput();
    expect(sinkInput, isNotNull);
    expect(sinkInput!['corked'], isTrue);
    // Always float32, at the server's rate and channel count
    expect(
      sinkInput['sample_specification'],
      '${floatSampleFormat()} ${format.channels}ch ${format.frequency}Hz',
    );
    expect(volumePercent(sinkInput), mixerPercent(0.8));

    // Playing uncorks the stream
    await playback.play();
    expect((await findSinkInput())!['corked'], isFalse);

    // Our own volume changes reach the mixer
    await playback.expectVolumesApplied((volume) async {
      expect(volumePercent((await findSinkInput())!), mixerPercent(volume));
    });

    // Mixer changes are reported back
    await Process.run('pactl', [
      'set-sink-input-volume',
      '${sinkInput['index']}',
      '30%',
    ]);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isNotEmpty);
    expect(externalVolumes.last, closeTo(pow(0.3, 3), 0.001));
    expect(await FlutterPcm.getVolume(), closeTo(pow(0.3, 3), 0.001));

    // Pausing corks the stream
    await playback.pause();
    expect((await findSinkInput())!['corked'], isTrue);
    await playback.resume();
    expect((await findSinkInput())!['corked'], isFalse);

    await playback.expectOddRepliesHandled();

    // A mixer boost above 100% is reported as 1
    await Process.run('pactl', [
      'set-sink-input-volume',
      '${sinkInput['index']}',
      '130%',
    ]);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes.length, 2);
    expect(externalVolumes.last, 1.0);
    expect(await FlutterPcm.getVolume(), 1.0);

    // A server restart pauses playback and reports it
    final restart = await Process.run('systemctl', [
      '--user',
      'restart',
      'pipewire',
      'pipewire-pulse',
    ]);
    expect(restart.exitCode, 0, reason: '${restart.stderr}');
    await Future.delayed(const Duration(milliseconds: 500));
    expect(playingChanges, [false]);
    final failedFrames = source.framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, failedFrames);

    // Playing while the server is down is refused and reported
    const pulseUnits = ['pipewire-pulse.socket', 'pipewire-pulse.service'];
    await Process.run('systemctl', ['--user', 'stop', ...pulseUnits]);
    try {
      await FlutterPcm.setPlaying(true);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(playingChanges, [false, false]);
      expect(source.framesRequested, failedFrames);
    } finally {
      await Process.run('systemctl', ['--user', 'start', ...pulseUnits]);
    }

    // Wait for the server to come back
    for (var i = 0; i < 50; i++) {
      if ((await Process.run('pactl', ['info'])).exitCode == 0) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Playing again reconnects with the format reported by setup, and the
    // volume including the boost, without reporting either back
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(seconds: 1));
    expect(playingChanges, [false, false]);
    expect(
      source.framesRequested,
      greaterThan(failedFrames + format.frequency / 2),
    );
    final newSinkInput = (await findSinkInput())!;
    expect(newSinkInput['corked'], isFalse);
    expect(
      newSinkInput['sample_specification'],
      '${floatSampleFormat()} ${format.channels}ch ${format.frequency}Hz',
    );
    expect(volumePercent(newSinkInput), 130);
    expect(externalVolumes.length, 2);
    await FlutterPcm.setPlaying(false);
  });
}
