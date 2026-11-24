// macOS and iOS integration test: plays silence through an output audio unit.
//
// Run with: flutter test integration_test/darwin_playback_test.dart -d macos
// (or -d <iOS simulator or device>)
//
// The test can't inspect the stream from the outside, and it doesn't cover
// iOS interruptions or route changes.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

import 'common.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause and volume', (WidgetTester tester) async {
    final source = SilentSource();
    final externalVolumes = <double>[];
    final playingChanges = <bool>[];

    // The volume starts at 1, and a volume set before setup is applied by it
    expect(await FlutterPcm.getVolume(), 1.0);
    await FlutterPcm.setVolume(0.8);

    late AudioFormat format;
    format = await FlutterPcm.setup(
      source.call,
      volumeCallback: externalVolumes.add,
      playingCallback: playingChanges.add,
    );
    source.format = format;

    expect(format.channels, 2);
    expect(format.frequency, greaterThan(0));

    // Nothing is pulled before playing
    await Future.delayed(const Duration(milliseconds: 300));
    expect(source.framesRequested, 0);
    expect(await FlutterPcm.getVolume(), closeTo(0.8, 0.001));

    // Playing pulls samples at roughly the sample rate
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(seconds: 2));
    final playedFrames = source.framesRequested;
    expect(playedFrames, greaterThan(format.frequency * 1.5));
    expect(playedFrames, lessThan(format.frequency * 2.5));
    expect(playingChanges, isEmpty);

    // Volume is a gain applied by the player; nothing reports it back
    await FlutterPcm.setVolume(0.5);
    expect(await FlutterPcm.getVolume(), closeTo(0.5, 0.001));
    await FlutterPcm.setVolume(1.5);
    expect(await FlutterPcm.getVolume(), 1.0);
    await FlutterPcm.setVolume(-1);
    expect(await FlutterPcm.getVolume(), 0.0);
    await FlutterPcm.setVolume(double.nan);
    expect(await FlutterPcm.getVolume(), 0.0);
    await FlutterPcm.setVolume(1);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isEmpty);

    // Pausing stops pulling samples
    await FlutterPcm.setPlaying(false);
    await Future.delayed(const Duration(milliseconds: 300));
    final pausedFrames = source.framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, pausedFrames);

    // And resumes
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, greaterThan(pausedFrames));

    // A slow reply is waited for, and playback continues at the normal rate
    // afterwards. The stall blocks the isolate, so the timer can't fire
    // before it is over.
    source.stallNextReply = true;
    await Future.delayed(const Duration(milliseconds: 300));
    expect(source.stallNextReply, isFalse);
    final afterStallFrames = source.framesRequested;
    await Future.delayed(const Duration(seconds: 2));
    expect(
      source.framesRequested - afterStallFrames,
      inInclusiveRange(format.frequency * 1.5, format.frequency * 2.5),
    );

    // Odd replies don't stop playback
    await expectOddRepliesHandled(source);

    expect(playingChanges, isEmpty);
    await FlutterPcm.setPlaying(false);
  });
}
