// Checks shared by the per-platform integration tests.

import 'dart:io';
import 'dart:typed_data';

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

/// Checks that replies of the wrong size, empty replies and a throwing
/// callback don't stop playback. Call while playing; afterwards, check that
/// no `onPlayingChanged` arrived.
Future<void> expectOddRepliesHandled(SilentSource source) async {
  final frequency = source.format.frequency;

  Future<void> expectNormalRate() async {
    final from = source.framesRequested;
    await Future.delayed(const Duration(seconds: 2));
    expect(
      source.framesRequested - from,
      inInclusiveRange(frequency * 1.5, frequency * 2.5),
    );
  }

  // Frames beyond those requested are dropped. If they were played, requests
  // would come at half the rate.
  source.reply = Reply.oversized;
  await expectNormalRate();

  // A trailing partial frame is dropped, so the channels stay aligned. On
  // Linux, writing it would fail the stream. Mono has no partial frames.
  if (source.format.channels > 1) {
    source.reply = Reply.partialFrame;
    await expectNormalRate();
  }
  source.reply = Reply.full;

  // Empty replies and a throwing callback play nothing. They are asked again
  // after a short delay, and playback goes on.
  for (final reply in [Reply.empty, Reply.throwing]) {
    source.oddRepliesLeft = 3;
    source.reply = reply;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.oddRepliesLeft, 0, reason: '$reply');
    final from = source.framesRequested;
    await Future.delayed(const Duration(milliseconds: 500));
    expect(source.framesRequested, greaterThan(from), reason: '$reply');
  }
}
