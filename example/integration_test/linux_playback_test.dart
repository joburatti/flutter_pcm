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

/// The mixer percentage for a volume. Our volume is a linear gain, and
/// PulseAudio's volume scale is cubic.
int mixerPercent(double volume) => (pow(volume, 1 / 3) * 100).round();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause, volume and server restart', (
    WidgetTester tester,
  ) async {
    var framesRequested = 0;
    final externalVolumes = <double>[];
    final playingChanges = <bool>[];
    var stallNextReply = false;

    // The volume starts at 1, and a volume set before setup is applied by it
    expect(await FlutterPcm.getVolume(), 1.0);
    FlutterPcm.setVolume(0.8);

    late AudioFormat format;
    format = await FlutterPcm.setup(
      (int maxFrames) {
        framesRequested += maxFrames;
        if (stallNextReply) {
          stallNextReply = false;
          // Blocks the isolate, like a long frame or a breakpoint would
          sleep(const Duration(milliseconds: 1500));
        }
        return Uint8List(maxFrames * format.channels * 4);
      },
      volumeCallback: externalVolumes.add,
      playingCallback: playingChanges.add,
    );

    expect(format.sampleFormat, SampleFormat.float32);
    expect(format.channels, greaterThan(0));
    expect(format.frequency, greaterThan(0));

    // The stream exists but starts corked, with the volume set before setup
    final sinkInput = await findSinkInput();
    expect(sinkInput, isNotNull);
    expect(sinkInput!['corked'], isTrue);
    expect(volumePercent(sinkInput), mixerPercent(0.8));
    expect(await FlutterPcm.getVolume(), closeTo(0.8, 0.001));
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
    expect(volumePercent((await findSinkInput())!), mixerPercent(0.5));
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    expect(externalVolumes, isEmpty);

    // Out of range volumes are clamped, and NaN is ignored
    FlutterPcm.setVolume(1.5);
    expect(await FlutterPcm.getVolume(), 1.0);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(volumePercent((await findSinkInput())!), 100);
    FlutterPcm.setVolume(-1);
    expect(await FlutterPcm.getVolume(), 0.0);
    FlutterPcm.setVolume(double.nan);
    expect(await FlutterPcm.getVolume(), 0.0);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(volumePercent((await findSinkInput())!), 0);

    // Dragging a slider sends many changes in a row; none may echo back
    for (var v = 0.0; v <= 1.0; v += 0.02) {
      FlutterPcm.setVolume(v);
      await Future.delayed(const Duration(milliseconds: 2));
    }
    FlutterPcm.setVolume(0.5);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isEmpty);
    expect(volumePercent((await findSinkInput())!), mixerPercent(0.5));

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
    expect(playingChanges, isEmpty);

    // A slow reply is waited for, and playback continues at the normal rate
    // afterwards. The stall blocks the isolate, so the timer can't fire
    // before it is over.
    stallNextReply = true;
    await Future.delayed(const Duration(milliseconds: 300));
    expect(stallNextReply, isFalse);
    final afterStallFrames = framesRequested;
    await Future.delayed(const Duration(seconds: 2));
    expect(
      framesRequested - afterStallFrames,
      inInclusiveRange(format.frequency * 1.5, format.frequency * 2.5),
    );
    expect(playingChanges, isEmpty);

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
    final failedFrames = framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, failedFrames);

    // Playing while the server is down is refused and reported
    const pulseUnits = ['pipewire-pulse.socket', 'pipewire-pulse.service'];
    await Process.run('systemctl', ['--user', 'stop', ...pulseUnits]);
    try {
      await FlutterPcm.setPlaying(true);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(playingChanges, [false, false]);
      expect(framesRequested, failedFrames);
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
    expect(framesRequested, greaterThan(failedFrames + format.frequency / 2));
    final newSinkInput = (await findSinkInput())!;
    expect(newSinkInput['corked'], isFalse);
    expect(
      newSinkInput['sample_specification'],
      contains('${format.channels}ch ${format.frequency}Hz'),
    );
    expect(volumePercent(newSinkInput), 130);
    expect(externalVolumes.length, 2);
    await FlutterPcm.setPlaying(false);
  });
}
