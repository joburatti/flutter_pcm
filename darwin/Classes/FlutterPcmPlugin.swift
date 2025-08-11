import AVFoundation
import AudioUnit

#if os(macOS)
    import Cocoa
    import FlutterMacOS
#elseif os(iOS)
    import Flutter
    import UIKit
#endif

enum SampleFormat: String {
    case unknown
    case float32
    case float64
    case uint8
    case uint16
    case uint32

    static func from(avAudioFormat: AVAudioCommonFormat) -> SampleFormat {
        switch avAudioFormat {
        case .pcmFormatFloat32:
            return .float32
        case .pcmFormatFloat64:
            return .float64
        case .pcmFormatInt16:
            return .uint16
        case .pcmFormatInt32:
            return .uint32
        default:
            return .unknown
        }
    }
}

public class FlutterPcmPlugin: NSObject, FlutterPlugin {
    var audioUnit: AUAudioUnit! = nil
    let channel: FlutterMethodChannel

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterPcmPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: instance.channel)
    }

    init(registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(
            name: "flutter_pcm",
            binaryMessenger: registrar.messenger
        )
        super.init()
    }

    deinit {
        if audioUnit != nil {
            audioUnit.stopHardware()
            audioUnit.deallocateRenderResources()
            audioUnit = nil
        }

        #if os(iOS)
            AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    public func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "setup":
            result(setup())
        case "setPlaying":
            result(nil)
        case "setVolume":
            result(nil)
        case "getVolume":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func setup() -> [String: Any]? {
        do {
            var result: [String: Any] = [:]

            #if os(macOS)
                let subType = kAudioUnitSubType_DefaultOutput
            #elseif os(iOS)
                let subType = kAudioUnitSubType_RemoteIO

                let audioSession = AVAudioSession.sharedInstance()
                // This will enable lock screen / silent mode playback. Other possible values would be Ambient or SoloAmbient
                audioSession.setCategory(AVAudioSessionCategoryPlayback)

                NotificationCenter.default.addObserver(
                    forName: NSNotification.Name.AVAudioSessionInterruption,
                    object: nil,
                    queue: nil,
                    using: audioSessionInterruptionHandler
                )

                try audioSession.setActive(true)
            #endif

            let descr = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: subType,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            try audioUnit = AUAudioUnit(componentDescription: descr)

            let bus0 = audioUnit.inputBusses[0]
            let format = bus0.format
            result["frequency"] = NSNumber(value: Int(format.sampleRate))
            result["channels"] = NSNumber(value: format.channelCount)
            result["sampleFormat"] =
                SampleFormat.from(avAudioFormat: format.commonFormat).rawValue

            audioUnit.outputProvider = fillSpeakerBuffer
            audioUnit.isOutputEnabled = true
            try audioUnit.allocateRenderResources()
            try audioUnit.startHardware()

            return result
        } catch let error as NSError {
            NSLog("%@", error.userInfo)
            return nil
        }
    }

    private func fillSpeakerBuffer(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestapm: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        inputBusNumber: Int,
        audioBufferListPtr: UnsafeMutablePointer<AudioBufferList>
    ) -> AUAudioUnitStatus {
        //        NSLog("flurp")
        /*
        let audioBufferList = UnsafeMutableAudioBufferListPointer(
            audioBufferListPtr
        )
        for audioBuffer in audioBufferList {
            let res: FlutterResult
        
            DispatchQueue.main.async {
                self.channel.invokeMethod("getSamples", arguments: frameCount, result: res)
            }
        
        }
         */
        return noErr
    }

    #if os(iOS)
        private func audioSessionInterruptionHandler(notification: Notification)
        {
            let interuptionDict = notification.userInfo
            if let interuptionType = interuptionDict?[
                AVAudioSessionInterruptionTypeKey
            ] {
                let interuptionVal = AVAudioSessionInterruptionType(
                    rawValue: (interuptionType as AnyObject).uintValue
                )
                if interuptionVal == AVAudioSessionInterruptionType.began {
                    if audioRunning {
                        audioUnit.stopHardware()
                        audioRunning = false
                    }
                }
            }
        }
    #endif
}
