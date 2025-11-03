package com.example.audio_streamer

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val channelName = "pcm_player"
    private lateinit var methodChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startPcm" -> {
                        val host = call.argument<String>("host") ?: "127.0.0.1"
                        val port = call.argument<Int>("port") ?: 7352
                        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                        val channels = call.argument<Int>("channels") ?: 2
                        val bits = call.argument<Int>("bits") ?: 16
                        Log.i("PcmClient", "startPcm host=$host port=$port sr=$sampleRate ch=$channels bits=$bits")
                        val intent = android.content.Intent(this, PcmService::class.java)
                        intent.putExtra("host", host)
                        intent.putExtra("port", port)
                        intent.putExtra("sampleRate", sampleRate)
                        intent.putExtra("channels", channels)
                        intent.putExtra("bits", bits)
                        androidx.core.content.ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }
                    "stopPcm" -> {
                        val intent = android.content.Intent(this, PcmService::class.java)
                        stopService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
