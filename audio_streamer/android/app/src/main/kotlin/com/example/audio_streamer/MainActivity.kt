package com.example.audio_streamer

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : FlutterActivity() {
    private val channelName = "pcm_player"
    private lateinit var methodChannel: MethodChannel
    private var pendingStartArgs: Bundle? = null
    private val notifPermReqCode = 1007

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

                        if (Build.VERSION.SDK_INT >= 33) {
                            val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                            if (!granted) {
                                // Save args and request permission, then start service in callback
                                pendingStartArgs = Bundle().apply {
                                    putString("host", host)
                                    putInt("port", port)
                                    putInt("sampleRate", sampleRate)
                                    putInt("channels", channels)
                                    putInt("bits", bits)
                                }
                                ActivityCompat.requestPermissions(this, arrayOf<String>(Manifest.permission.POST_NOTIFICATIONS), notifPermReqCode)
                                result.success(null)
                                return@setMethodCallHandler
                            }
                        }

                        val intent = android.content.Intent(this, PcmService::class.java)
                        intent.putExtra("host", host)
                        intent.putExtra("port", port)
                        intent.putExtra("sampleRate", sampleRate)
                        intent.putExtra("channels", channels)
                        intent.putExtra("bits", bits)
                        ContextCompat.startForegroundService(this, intent)
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

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notifPermReqCode) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            val args = pendingStartArgs
            pendingStartArgs = null
            if (granted && args != null) {
                val intent = android.content.Intent(this, PcmService::class.java)
                intent.putExtras(args)
                ContextCompat.startForegroundService(this, intent)
            }
        }
    }
}
