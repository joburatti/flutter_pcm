// Integration test for every platform: setPlaying(true) before setup starts
// playback as soon as setup has run.
//
// Run with: flutter test integration_test/play_before_setup_test.dart -d <device>
//
// It is a file of its own because setup can only be called once per process,
// and the platform tests check that setup alone doesn't play.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

import 'common.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('play before setup', (WidgetTester tester) async {
    final playback = Playback();

    await playback.setup(playing: true);
    await playback.expectNormalRate();
    expect(playback.playingChanges, isEmpty);

    await playback.pause();
    await playback.resume();

    await FlutterPcm.setPlaying(false);
  });
}
