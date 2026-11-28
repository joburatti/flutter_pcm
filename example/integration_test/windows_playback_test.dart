// Windows-only integration test: plays silence through WASAPI on the default
// render endpoint. It checks our session's volume from the outside, the way
// the Volume Mixer sees it, with a PowerShell script.
//
// Run with: flutter test integration_test/windows_playback_test.dart -d windows
//
// To check device failure, it disables the default render endpoint for a
// moment (with Disable-PnpDevice, which needs admin rights), which interrupts
// any other audio.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_pcm/flutter_pcm.dart';

import 'common.dart';

/// With `session`, prints the master volume of the given process' audio
/// session on the default render endpoint, after setting it if a volume is
/// given, and then the session's state (0 inactive, 1 active). Setting the
/// volume this way is what the Volume Mixer does. With `endpoint`, prints the
/// default render endpoint's id.
const _audioScript = r'''
param([string]$Command, [int]$ProcessId, [string]$Volume)
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
  int OpenPropertyStore(int access, out IntPtr properties);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
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

public static class Audio {
  // Null if there is none
  static IMMDevice DefaultEndpoint() {
    var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
    IMMDevice device;
    var hr = enumerator.GetDefaultAudioEndpoint(0 /* eRender */,
                                                1 /* eMultimedia */, out device);
    if (hr == unchecked((int)0x80070490) /* E_NOTFOUND */) {
      return null;
    }
    Marshal.ThrowExceptionForHR(hr);
    return device;
  }

  // Empty if there is none
  public static string EndpointId() {
    var device = DefaultEndpoint();
    if (device == null) {
      return "";
    }
    string id;
    Marshal.ThrowExceptionForHR(device.GetId(out id));
    return id;
  }

  public static string Session(int processId, string volume) {
    var device = DefaultEndpoint();
    if (device == null) {
      throw new Exception("No default render endpoint");
    }
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
switch ($Command) {
  'session' { [Audio]::Session($ProcessId, $Volume) }
  'endpoint' { [Audio]::EndpointId() }
}
''';

/// Runs PowerShell [arguments] and returns what it printed
Future<String> powershell(List<String> arguments) async {
  final res = await Process.run('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    ...arguments,
  ]);
  expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
  return (res.stdout as String).trim();
}

/// Runs [_audioScript] with [arguments]
Future<String> audioScript(List<String> arguments) async {
  final script = File('${Directory.systemTemp.path}\\flutter_pcm_audio.ps1');
  await script.writeAsString(_audioScript);
  return powershell(['-File', script.path, ...arguments]);
}

/// Our session's volume and whether it is active, as the Volume Mixer sees
/// them, after setting the volume from the outside if [set] is given.
Future<({double volume, bool active})> session([double? set]) async {
  final [volume, state] = (await audioScript([
    'session',
    '$pid',
    if (set != null) '$set',
  ])).split(' ');
  return (volume: double.parse(volume), active: state == '1');
}

Future<double> sessionVolume([double? set]) async =>
    (await session(set)).volume;

Future<bool> sessionActive() async => (await session()).active;

/// The default render endpoint's id, like `{0.0.0.00000000}.{<guid>}`, or an
/// empty string if there is none
Future<String> defaultEndpoint() => audioScript(['endpoint', '0']);

/// Enables or disables an endpoint, like the Sound settings do. Its device
/// instance id is its endpoint id under `SWD\MMDEVAPI`.
Future<void> setEndpointEnabled(String endpoint, bool enabled) async {
  final cmdlet = enabled ? 'Enable-PnpDevice' : 'Disable-PnpDevice';
  await powershell([
    '-Command',
    "$cmdlet -InstanceId 'SWD\\MMDEVAPI\\$endpoint' -Confirm:\$false",
  ]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback, pause, volume and device failure', (
    WidgetTester tester,
  ) async {
    final playback = Playback();
    final source = playback.source;
    final externalVolumes = playback.externalVolumes;
    final playingChanges = playback.playingChanges;

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

    // Disabling the device pauses playback and reports it
    final endpoint = await defaultEndpoint();
    await setEndpointEnabled(endpoint, false);
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      expect(playingChanges, [false]);
      final failedFrames = source.framesRequested;
      await Future.delayed(const Duration(milliseconds: 500));
      expect(source.framesRequested, failedFrames);

      // Playing without a device is refused and reported
      await FlutterPcm.setPlaying(true);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(playingChanges, [false, false]);
      expect(source.framesRequested, failedFrames);

      // A volume set without a device is kept
      await FlutterPcm.setVolume(0.6);
      expect(await FlutterPcm.getVolume(), closeTo(0.6, 0.001));
    } finally {
      await setEndpointEnabled(endpoint, true);
    }

    // Wait for the endpoint to be the default again
    for (var i = 0; i < 50 && await defaultEndpoint() != endpoint; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(await defaultEndpoint(), endpoint);

    // Playing again reopens the device at the rate reported by setup, and
    // applies the volume set meanwhile, without reporting either back
    await FlutterPcm.setPlaying(true);
    await playback.expectNormalRate();
    expect(playingChanges, [false, false]);
    expect(await sessionActive(), isTrue);
    expect(await sessionVolume(), closeTo(0.6, 0.001));
    expect(externalVolumes.length, 1);

    await FlutterPcm.setPlaying(false);
  });
}
