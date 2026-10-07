package com.example.flutter_pcm_example

import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Lets the integration test take audio focus from the plugin's player, the
    // way a phone call or another app would. Focus is tracked per listener, so
    // this competes with the player although it is in the same app.
    private val focusListener = AudioManager.OnAudioFocusChangeListener {}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val audioManager = getSystemService(AudioManager::class.java)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "flutter_pcm_example/focus")
            .setMethodCallHandler { call, result ->
                @Suppress("DEPRECATION")
                when (call.method) {
                    "request" -> {
                        val hint = if (call.arguments == true) {
                            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                        } else {
                            AudioManager.AUDIOFOCUS_GAIN
                        }
                        val granted = audioManager.requestAudioFocus(
                            focusListener, AudioManager.STREAM_MUSIC, hint,
                        ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
                        result.success(granted)
                    }

                    "abandon" -> {
                        audioManager.abandonAudioFocus(focusListener)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
