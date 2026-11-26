// Checks shared by the per-platform integration tests.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

enum Reply { full, oversized, partialFrame, empty, throwing }

/// A sample callback that replies with silence and counts the frames it
/// supplied. Pass [call] to [FlutterPcm.setup], then set [format].
class SilentSource {
  late AudioFormat format;
  var framesRequested = 0;

  /// The shape of the next replies
  var reply = Reply.full;

  /// How many replies are [Reply.empty] or [Reply.throwing], after which
  /// [reply] goes back to [Reply.full]
  var oddRepliesLeft = 0;

  /// Blocks the isolate before the next reply, like a long frame or a
  /// breakpoint would
  var stallNextReply = false;

  Float32List call(int maxFrames) {
    if (stallNextReply) {
      stallNextReply = false;
      sleep(const Duration(milliseconds: 1500));
    }

    final samples = maxFrames * format.channels;
    switch (reply) {
      case Reply.empty || Reply.throwing:
        final throwing = reply == Reply.throwing;
        if (--oddRepliesLeft <= 0) {
          reply = Reply.full;
        }
        if (throwing) {
          throw StateError('No samples');
        }
        return Float32List(0);
      case Reply.full:
        framesRequested += maxFrames;
        return Float32List(samples);
      case Reply.oversized:
        framesRequested += maxFrames;
        return Float32List(samples * 2);
      case Reply.partialFrame:
        framesRequested += maxFrames;
        return Float32List(samples - 1);
    }
  }
}

/// The steps every platform test takes, in this order, with its own checks
/// in between. Setup can only be called once per process, so each test file
/// uses one [Playback].
class Playback {
  final source = SilentSource();
  final externalVolumes = <double>[];
  final playingChanges = <bool>[];

  AudioFormat get format => source.format;

  /// Checks the volume before setup, sets it to 0.8 and sets up. Without
  /// [playing], checks that nothing is pulled afterwards. With [playing],
  /// calls `setPlaying(true)` before setup, so playback starts with it.
  Future<void> setup({bool playing = false}) async {
    // The volume starts at 1, and a volume set before setup is applied by it
    expect(await FlutterPcm.getVolume(), 1.0);
    await FlutterPcm.setVolume(0.8);
    if (playing) {
      await FlutterPcm.setPlaying(true);
    }

    source.format = await FlutterPcm.setup(
      source.call,
      volumeCallback: externalVolumes.add,
      playingCallback: playingChanges.add,
    );
    expect(format.channels, greaterThan(0));
    expect(format.frequency, greaterThan(0));
    expect(await FlutterPcm.getVolume(), closeTo(0.8, 0.001));

    // A second setup fails and keeps the first one's callbacks. If it kept
    // these instead, the later checks would see no frames pulled and no
    // volume or playing changes.
    await expectLater(
      FlutterPcm.setup((_) => Float32List(0)),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'already_set_up',
        ),
      ),
    );

    // Setup alone doesn't play
    if (!playing) {
      await expectNoPulling();
      expect(source.framesRequested, 0);
    }
  }

  /// Checks that samples are pulled at roughly the sample rate for two
  /// seconds
  Future<void> expectNormalRate() async {
    final from = source.framesRequested;
    await Future.delayed(const Duration(seconds: 2));
    expect(
      source.framesRequested - from,
      inInclusiveRange(format.frequency * 1.5, format.frequency * 2.5),
    );
  }

  /// Checks that no samples are pulled, after letting a request that was
  /// already sent finish
  Future<void> expectNoPulling() async {
    await Future.delayed(const Duration(milliseconds: 300));
    final from = source.framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, from);
  }

  /// Plays for the first time
  Future<void> play() async {
    await FlutterPcm.setPlaying(true);
    await expectNormalRate();
    expect(playingChanges, isEmpty);
  }

  /// Checks that our volume changes are applied, clamped and not reported
  /// back. Pass [inMixer] to check each volume where the system shows it
  /// (Windows and Linux). Leaves the volume at 0.5.
  Future<void> expectVolumesApplied([
    Future<void> Function(double volume)? inMixer,
  ]) async {
    Future<void> setVolume(double volume, double expected) async {
      await FlutterPcm.setVolume(volume);
      expect(await FlutterPcm.getVolume(), closeTo(expected, 0.001));
      if (inMixer != null) {
        await Future.delayed(const Duration(milliseconds: 300));
        await inMixer(expected);
      }
    }

    await setVolume(0.5, 0.5);

    // Out of range volumes are clamped, and NaN is ignored
    await setVolume(1.5, 1.0);
    await setVolume(-1, 0.0);
    await setVolume(double.nan, 0.0);

    // Dragging a slider sends many changes in a row
    for (var v = 0.0; v <= 1.0; v += 0.02) {
      await FlutterPcm.setVolume(v);
      await Future.delayed(const Duration(milliseconds: 2));
    }
    await setVolume(0.5, 0.5);

    // None of them is reported back
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isEmpty);
  }

  /// Pauses, which stops pulling samples
  Future<void> pause() async {
    await FlutterPcm.setPlaying(false);
    await expectNoPulling();
  }

  /// Resumes after [pause]
  Future<void> resume() async {
    final from = source.framesRequested;
    await FlutterPcm.setPlaying(true);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, greaterThan(from));
    expect(playingChanges, isEmpty);
  }

  /// Checks that a slow reply, replies of the wrong size, empty replies and
  /// a throwing callback don't stop playback. Call while playing.
  Future<void> expectOddRepliesHandled() async {
    // A slow reply is waited for, and playback continues at the normal rate
    // afterwards. The stall blocks the isolate, so the timer can't fire
    // before it is over.
    source.stallNextReply = true;
    await Future.delayed(const Duration(milliseconds: 300));
    expect(source.stallNextReply, isFalse);
    await expectNormalRate();

    // Frames beyond those requested are dropped. If they were played,
    // requests would come at half the rate.
    source.reply = Reply.oversized;
    await expectNormalRate();

    // A trailing partial frame is dropped, so the channels stay aligned. On
    // Linux, writing it would fail the stream. Mono has no partial frames.
    if (format.channels > 1) {
      source.reply = Reply.partialFrame;
      await expectNormalRate();
    }
    source.reply = Reply.full;

    // Empty replies and a throwing callback play nothing. They are asked
    // again after a short delay, and playback goes on.
    for (final reply in [Reply.empty, Reply.throwing]) {
      source.oddRepliesLeft = 3;
      source.reply = reply;
      await Future.delayed(const Duration(milliseconds: 500));
      expect(source.oddRepliesLeft, 0, reason: '$reply');
      final from = source.framesRequested;
      await Future.delayed(const Duration(milliseconds: 500));
      expect(source.framesRequested, greaterThan(from), reason: '$reply');
    }

    expect(playingChanges, isEmpty);
  }
}
