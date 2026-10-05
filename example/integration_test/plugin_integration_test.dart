// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('setup test', (WidgetTester tester) async {
    final result = await FlutterPcm.setup(
      (int i) => Float32List(i).buffer.asUint8List(),
    );
    expect(result!.frequency, 48000);
    expect(result.channels, 2);
    expect(result.sampleFormat, SampleFormat.float32);
  });
}
