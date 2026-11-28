// Android-only integration test: plays silence through AudioTrack.
//
// Run with: flutter test integration_test/android_playback_test.dart -d <device>
//
// The test runs on the device, so it can't inspect the stream from the
// outside the way the Linux test does with pactl. Audio focus is taken away
// through a channel in the example's MainActivity, which requests focus
// itself the way a phone call or another app would.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

import 'common.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause, volume and audio focus', (
    WidgetTester tester,
  ) async {
    final playback = Playback();
    final source = playback.source;
    final playingChanges = playback.playingChanges;

    await playback.setup();
    expect(playback.format.channels, 2);

    await playback.play();
    // Volume is a per-track gain; nothing reports it back
    await playback.expectVolumesApplied();
    await playback.pause();
    await playback.resume();
    await playback.expectOddRepliesHandled();

    const focus = MethodChannel('flutter_pcm_example/focus');
    // Takes focus as `gain` (permanently), `transient` or `duck` (transient,
    // letting others duck)
    Future<void> takeFocus(String kind) async {
      expect(await focus.invokeMethod<bool>('request', kind), isTrue);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    Future<void> returnFocus() async {
      await focus.invokeMethod<void>('abandon');
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // A transient loss that lets us duck (like a notification) keeps playing.
    // Since Android 8 the system lowers our volume; before, the player does.
    // Neither changes the volume the app set.
    await takeFocus('duck');
    final duckedFrom = source.framesRequested;
    await Future.delayed(const Duration(milliseconds: 300));
    expect(source.framesRequested, greaterThan(duckedFrom));
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    await returnFocus();
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    expect(playingChanges, isEmpty);

    // A transient focus loss (like a phone call) pauses, and regaining focus
    // resumes. Both are reported.
    await takeFocus('transient');
    expect(playingChanges, [false]);
    await playback.expectNoPulling();
    final resumedFrom = source.framesRequested;
    await returnFocus();
    expect(playingChanges, [false, true]);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(source.framesRequested, greaterThan(resumedFrom));

    // Pausing while waiting for focus cancels the resume
    await takeFocus('transient');
    expect(playingChanges, [false, true, false]);
    await FlutterPcm.setPlaying(false);
    await returnFocus();
    expect(playingChanges, [false, true, false]);
    await playback.expectNoPulling();

    // A permanent loss pauses until the app plays again
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 300));
    await takeFocus('gain');
    expect(playingChanges, [false, true, false, false]);
    await returnFocus();
    expect(playingChanges, [false, true, false, false]);
    await playback.expectNoPulling();

    // Playing again takes focus back
    final replayedFrom = source.framesRequested;
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, greaterThan(replayedFrom));
    expect(playingChanges, [false, true, false, false]);

    await FlutterPcm.setPlaying(false);
  });
}
