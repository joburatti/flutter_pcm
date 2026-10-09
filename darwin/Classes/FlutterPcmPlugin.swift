import Foundation

#if os(macOS)
    import FlutterMacOS
#elseif os(iOS)
    import Flutter
#endif

// Names must match the Dart SampleFormat enum
enum SampleFormat: String {
    case float32
    case float64
    case uint8
    case uint16
    case uint32
}

public class FlutterPcmPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private let player: PcmPlayer

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterPcmPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: instance.channel)
    }

    init(registrar: FlutterPluginRegistrar) {
        #if os(macOS)
            let messenger = registrar.messenger
        #elseif os(iOS)
            let messenger = registrar.messenger()
        #endif
        let channel = FlutterMethodChannel(
            name: "flutter_pcm",
            binaryMessenger: messenger
        )
        self.channel = channel
        // The player calls these on the main thread
        player = PcmPlayer(
            sampleCallback: { maxFrames, completion in
                channel.invokeMethod("getSamples", arguments: maxFrames) {
                    reply in
                    completion((reply as? FlutterStandardTypedData)?.data)
                }
            },
            playingCallback: { playing in
                channel.invokeMethod("onPlayingChanged", arguments: playing)
            }
        )
        super.init()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        player.release()
    }

    public func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "setup":
            guard !player.isSetUp else {
                result(
                    FlutterError(
                        code: "already_set_up",
                        message: "setup has already been called",
                        details: nil
                    )
                )
                return
            }
            do {
                let format = try player.setup()
                result([
                    "frequency": format.frequency,
                    "channels": format.channels,
                    "sampleFormat": SampleFormat.float32.rawValue,
                ])
            } catch {
                NSLog("flutter_pcm: setup failed: %@", "\(error)")
                result(nil)
            }
        case "setPlaying":
            guard let playing = call.arguments as? Bool else {
                result(
                    FlutterError(
                        code: "bad_arguments",
                        message: "setPlaying takes a bool",
                        details: nil
                    )
                )
                return
            }
            player.setPlaying(playing)
            result(nil)
        case "setVolume":
            if let volume = call.arguments as? Double {
                player.volume = Float(volume)
            }
            result(nil)
        case "getVolume":
            result(Double(player.volume))
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
