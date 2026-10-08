// macOS and iOS integration test: plays silence through an output audio unit.
//
// Run with: flutter test integration_test/darwin_playback_test.dart -d macos
// (or -d <iOS simulator or device>)
//
// The test can't inspect the stream from the outside, and it doesn't cover
// iOS interruptions or route changes.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause and volume', (WidgetTester tester) async {
    var framesRequested = 0;
    final externalVolumes = <double>[];
    final playingChanges = <bool>[];
    var stallNextReply = false;
    var emptyReplies = 0;

    late AudioFormat format;
    final result = await FlutterPcm.setup(
      (int maxFrames) {
        if (emptyReplies > 0) {
          emptyReplies--;
          return Uint8List(0);
        }
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

    // Volume is a gain applied by the player; nothing reports it back
    FlutterPcm.setVolume(0.5);
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    FlutterPcm.setVolume(1.5);
    expect(await FlutterPcm.getVolume(), 1.0);
    FlutterPcm.setVolume(-1);
    expect(await FlutterPcm.getVolume(), 0.0);
    FlutterPcm.setVolume(1);
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

    // Empty replies are asked again, and playback goes on
    emptyReplies = 3;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(emptyReplies, 0);
    final afterEmptyFrames = framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(framesRequested, greaterThan(afterEmptyFrames));

    expect(playingChanges, isEmpty);
    await FlutterPcm.setPlaying(false);
  });
}
