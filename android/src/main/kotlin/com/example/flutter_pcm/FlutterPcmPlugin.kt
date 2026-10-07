package com.example.flutter_pcm

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class FlutterPcmPlugin : FlutterPlugin, MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())

    // Main thread only
    private var channel: MethodChannel? = null
    private var player: PcmPlayer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val newChannel = MethodChannel(binding.binaryMessenger, "flutter_pcm")
        newChannel.setMethodCallHandler(this)
        channel = newChannel
        player = PcmPlayer(binding.applicationContext, ::callSampleCallback) { playing ->
            channel?.invokeMethod("onPlayingChanged", playing)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Joins the audio thread, so no sample requests are posted after this
        player?.release()
        player = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val player = player ?: return result.error("not_attached", "Plugin is detached", null)

        when (call.method) {
            "setup" -> {
                val format = try {
                    player.setup()
                } catch (e: RuntimeException) {
                    return result.error("setup_failed", e.message, null)
                }
                result.success(
                    mapOf(
                        "frequency" to format.frequency,
                        "channels" to format.channels,
                        "sampleFormat" to format.sampleFormat.name,
                    )
                )
            }

            "setPlaying" -> {
                val playing = call.arguments as? Boolean
                    ?: return result.error("bad_arguments", "Bad arguments for setPlaying", null)
                // Reply first, so that a denied focus request's
                // onPlayingChanged(false) arrives after setPlaying completes
                result.success(null)
                player.setPlaying(playing)
            }

            "setVolume" -> {
                val volume = call.arguments as? Double
                    ?: return result.error("bad_arguments", "Bad arguments for setVolume", null)
                player.setVolume(volume.toFloat())
                result.success(null)
            }

            "getVolume" -> result.success(player.getVolume().toDouble())

            else -> result.notImplemented()
        }
    }

    // Called on the audio thread. Channel calls must happen on the main
    // thread, so post the request there. The reply goes to the player, unless
    // the plugin was detached meanwhile.
    private fun callSampleCallback(maxFrames: Int) {
        mainHandler.post {
            val channel = channel ?: return@post
            channel.invokeMethod("getSamples", maxFrames, object : Result {
                override fun success(result: Any?) {
                    player?.onSamples(result as? ByteArray)
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    player?.onSamples(null)
                }

                override fun notImplemented() {
                    player?.onSamples(null)
                }
            })
        }
    }
}
