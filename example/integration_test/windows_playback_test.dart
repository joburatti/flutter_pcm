// Windows-only integration test: plays silence through WASAPI on the default
// render endpoint. It checks our session's volume from the outside, the way
// the Volume Mixer sees it, with a PowerShell script.
//
// Run with: flutter test integration_test/windows_playback_test.dart -d windows
//
// Device failure (unplugging the endpoint) is not covered; see CLAUDE.md for
// checking it by hand.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

import 'common.dart';

/// Prints the master volume of the given process' audio session on the
/// default render endpoint, after setting it if a volume is given, and then
/// the session's state (0 inactive, 1 active). Setting the volume this way is
/// what the Volume Mixer does.
const _sessionVolumeScript = r'''
param([int]$ProcessId, [string]$Volume)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System;
using System.Globalization;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumerator {}

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
               [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
  int GetAudioSessionControl(IntPtr sessionGuid, int flags, out IntPtr control);
  int GetSimpleAudioVolume(IntPtr sessionGuid, int flags, out IntPtr volume);
  int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator {
  int GetCount(out int count);
  int GetSession(int index, out IAudioSessionControl2 session);
}

// Declares the IAudioSessionControl methods first, since COM interop doesn't
// inherit them.
[ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl2 {
  int GetState(out int state);
  int GetDisplayName(out IntPtr name);
  int SetDisplayName(IntPtr name, IntPtr context);
  int GetIconPath(out IntPtr path);
  int SetIconPath(IntPtr path, IntPtr context);
  int GetGroupingParam(out Guid param);
  int SetGroupingParam(IntPtr param, IntPtr context);
  int RegisterAudioSessionNotification(IntPtr client);
  int UnregisterAudioSessionNotification(IntPtr client);
  int GetSessionIdentifier(out IntPtr id);
  int GetSessionInstanceIdentifier(out IntPtr id);
  int GetProcessId(out uint processId);
}

[ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISimpleAudioVolume {
  int SetMasterVolume(float level, ref Guid context);
  int GetMasterVolume(out float level);
}

public static class SessionVolume {
  public static string Run(int processId, string volume) {
    var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
    IMMDevice device;
    Marshal.ThrowExceptionForHR(
        enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */,
                                           out device));
    var iid = typeof(IAudioSessionManager2).GUID;
    object manager;
    Marshal.ThrowExceptionForHR(
        device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out manager));
    IAudioSessionEnumerator sessions;
    Marshal.ThrowExceptionForHR(
        ((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions));
    int count;
    sessions.GetCount(out count);
    for (var i = 0; i < count; i++) {
      IAudioSessionControl2 session;
      sessions.GetSession(i, out session);
      uint pid;
      session.GetProcessId(out pid);
      if (pid != processId) {
        continue;
      }
      var simpleVolume = (ISimpleAudioVolume)session;
      if (!String.IsNullOrEmpty(volume)) {
        var context = Guid.NewGuid();
        Marshal.ThrowExceptionForHR(simpleVolume.SetMasterVolume(
            Single.Parse(volume, CultureInfo.InvariantCulture), ref context));
      }
      float level;
      Marshal.ThrowExceptionForHR(simpleVolume.GetMasterVolume(out level));
      int state;
      Marshal.ThrowExceptionForHR(session.GetState(out state));
      return level.ToString(CultureInfo.InvariantCulture) + " " + state;
    }
    throw new Exception("No audio session for process " + processId);
  }
}
"@
[SessionVolume]::Run($ProcessId, $Volume)
''';

/// Our session's volume and whether it is active, as the Volume Mixer sees
/// them, after setting the volume from the outside if [set] is given.
Future<({double volume, bool active})> session([double? set]) async {
  final script = File(
    '${Directory.systemTemp.path}\\flutter_pcm_session_volume.ps1',
  );
  await script.writeAsString(_sessionVolumeScript);
  final res = await Process.run('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
    '$pid',
    if (set != null) '$set',
  ]);
  expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
  final [volume, state] = (res.stdout as String).trim().split(' ');
  return (volume: double.parse(volume), active: state == '1');
}

Future<double> sessionVolume([double? set]) async =>
    (await session(set)).volume;

Future<bool> sessionActive() async => (await session()).active;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause and volume', (WidgetTester tester) async {
    final playback = Playback();
    final externalVolumes = playback.externalVolumes;

    await playback.setup();

    // The stream isn't running, and the volume set before setup replaced the
    // session's
    expect(await sessionActive(), isFalse);
    expect(await sessionVolume(), closeTo(0.8, 0.001));

    // Playing starts the stream
    await playback.play();
    expect(await sessionActive(), isTrue);

    // Our own volume changes reach the mixer
    await playback.expectVolumesApplied((volume) async {
      expect(await sessionVolume(), closeTo(volume, 0.001));
    });

    // Mixer changes are reported back
    expect(await sessionVolume(0.3), closeTo(0.3, 0.001));
    await Future.delayed(const Duration(milliseconds: 300));
    expect(externalVolumes, isNotEmpty);
    expect(externalVolumes.last, closeTo(0.3, 0.001));
    expect(await FlutterPcm.getVolume(), closeTo(0.3, 0.001));

    // Pausing stops the stream
    await playback.pause();
    expect(await sessionActive(), isFalse);
    await playback.resume();
    expect(await sessionActive(), isTrue);

    await playback.expectOddRepliesHandled();

    await FlutterPcm.setPlaying(false);
  });
}
