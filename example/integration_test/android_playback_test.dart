// Android-only integration test: plays silence through AudioTrack.
//
// Run with: flutter test integration_test/android_playback_test.dart -d <device>
//
// The test runs on the device, so it can't inspect the stream from the
// outside the way the Linux test does with pactl. Audio focus is taken away
// through a channel in the example's MainActivity, which requests focus
// itself the way a phone call or another app would.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause, volume and audio focus', (
    WidgetTester tester,
  ) async {
    var framesRequested = 0;
    final externalVolumes = <double>[];
    final playingChanges = <bool>[];
    var stallNextReply = false;

    late AudioFormat format;
    final result = await FlutterPcm.setup(
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

    expect(result, isNotNull);
    format = result!;
    expect(format.sampleFormat, SampleFormat.float32);
    expect(format.channels, 2);
    expect(format.frequency, greaterThan(0));

    // Nothing is pulled before playing
    await Future.delayed(const Duration(milliseconds: 300));
    expect(framesRequested, 0);

    // Playing pulls samples at roughly the sample rate
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(seconds: 2));
    final playedFrames = framesRequested;
    expect(playedFrames, greaterThan(format.frequency * 1.5));
    expect(playedFrames, lessThan(format.frequency * 2.5));
    expect(playingChanges, isEmpty);

    // Volume is a per-track gain; nothing reports it back
    FlutterPcm.setVolume(0.5);
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    FlutterPcm.setVolume(1.5);
    expect(await FlutterPcm.getVolume(), 1.0);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isEmpty);

    // Pausing stops pulling samples
    await FlutterPcm.setPlaying(false);
    await Future.delayed(const Duration(milliseconds: 300));
    final pausedFrames = framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, pausedFrames);

    // And resumes
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, greaterThan(pausedFrames));

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

    const focus = MethodChannel('flutter_pcm_example/focus');
    Future<void> takeFocus({required bool transient}) async {
      expect(await focus.invokeMethod<bool>('request', transient), isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    Future<void> returnFocus() async {
      await focus.invokeMethod<void>('abandon');
      await Future.delayed(const Duration(milliseconds: 300));
    }

    Future<void> expectNoPulling() async {
      final frames = framesRequested;
      await Future.delayed(const Duration(milliseconds: 500));
      expect(framesRequested, frames);
    }

    // A transient focus loss (like a phone call) pauses, and regaining focus
    // resumes. Both are reported.
    await takeFocus(transient: true);
    expect(playingChanges, [false]);
    await expectNoPulling();
    final resumedFrom = framesRequested;
    await returnFocus();
    expect(playingChanges, [false, true]);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(framesRequested, greaterThan(resumedFrom));

    // Pausing while waiting for focus cancels the resume
    await takeFocus(transient: true);
    expect(playingChanges, [false, true, false]);
    await FlutterPcm.setPlaying(false);
    await returnFocus();
    expect(playingChanges, [false, true, false]);
    await expectNoPulling();

    // A permanent loss pauses until the app plays again
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 300));
    await takeFocus(transient: false);
    expect(playingChanges, [false, true, false, false]);
    await returnFocus();
    expect(playingChanges, [false, true, false, false]);
    await expectNoPulling();

    // Playing again takes focus back
    final replayedFrom = framesRequested;
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, greaterThan(replayedFrom));
    expect(playingChanges, [false, true, false, false]);

    await FlutterPcm.setPlaying(false);
  });
}
