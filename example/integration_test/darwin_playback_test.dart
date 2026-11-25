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
    final playback = Playback();

    await playback.setup();
    expect(playback.format.channels, 2);

    await playback.play();
    // Volume is a gain applied by the player; nothing reports it back
    await playback.expectVolumesApplied();
    await playback.pause();
    await playback.resume();
    await playback.expectOddRepliesHandled();

    await FlutterPcm.setPlaying(false);
  });
}
