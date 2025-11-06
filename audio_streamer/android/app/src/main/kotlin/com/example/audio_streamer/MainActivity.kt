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
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.content.Context
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
    private var boundNetwork: Network? = null

    companion object {
        @JvmStatic
        var methodChannelStatic: MethodChannel? = null
        @JvmStatic
        var lastPcmEventType: String? = null
        @JvmStatic
        var lastPcmEventMessage: String? = null
        @JvmStatic
        var lastHost: String? = null
        @JvmStatic
        var lastPort: Int? = null
        @JvmStatic
        var lastSr: Int? = null
        @JvmStatic
        var lastCh: Int? = null
        @JvmStatic
        var lastBits: Int? = null

        @JvmStatic
        fun sendPcmEvent(type: String, message: String? = null) {
            val map = HashMap<String, Any?>()
            map["type"] = type
            if (message != null) map["message"] = message
            lastPcmEventType = type
            lastPcmEventMessage = message
            val ch = methodChannelStatic
            if (ch != null) {
                val r = Runnable {
                    try {
                        ch.invokeMethod("pcmEvent", map)
                    } catch (t: Throwable) {
                        Log.w("MainActivity", "Failed to send pcmEvent: $type", t)
                    }
                }
                if (Looper.myLooper() == Looper.getMainLooper()) r.run() else Handler(Looper.getMainLooper()).post(r)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
    methodChannelStatic = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasUsbNetwork" -> {
                        result.success(findUsbNetwork() != null)
                    }
                    "bindUsbNetwork" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        val ok = if (enable) bindToUsbNetwork() else unbindNetwork()
                        result.success(ok)
                    }
                    "openUsbTetherSettings" -> {
                        val ok = openUsbTetherSettings()
                        result.success(ok)
                    }
                    "getPcmState" -> {
                        val map = HashMap<String, Any?>()
                        map["type"] = lastPcmEventType
                        map["message"] = lastPcmEventMessage
                        result.success(map)
                    }
                    "startPcm" -> {
                        val host = call.argument<String>("host") ?: "127.0.0.1"
                        val port = call.argument<Int>("port") ?: 7352
                        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                        val channels = call.argument<Int>("channels") ?: 2
                        val bits = call.argument<Int>("bits") ?: 16
                        val targetMs = call.argument<Int>("targetMs") ?: 40
                        val prefill = call.argument<Int>("prefill") ?: 6
                        val capacity = call.argument<Int>("capacity") ?: 16
                        Log.i("PcmClient", "startPcm host=$host port=$port sr=$sampleRate ch=$channels bits=$bits")

                        // Avoid duplicate restarts if already connecting/connected with same config
                        val current = lastPcmEventType
                        val sameCfg = (lastHost == host && lastPort == port && lastSr == sampleRate && lastCh == channels && lastBits == bits)
                        if ((current == "connected" || current == "connecting") && sameCfg) {
                            result.success(null)
                            return@setMethodCallHandler
                        }

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
                        intent.putExtra("targetMs", targetMs)
                        intent.putExtra("prefill", prefill)
                        intent.putExtra("capacity", capacity)
                        lastHost = host
                        lastPort = port
                        lastSr = sampleRate
                        lastCh = channels
                        lastBits = bits
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

    private fun findUsbNetwork(): Network? {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val nets = cm.allNetworks
            nets.firstOrNull { n ->
                val caps = cm.getNetworkCapabilities(n)
                caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_USB) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
            }
        } catch (_: Throwable) { null }
    }

    private fun bindToUsbNetwork(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = findUsbNetwork() ?: return false
            val ok = if (Build.VERSION.SDK_INT >= 23) cm.bindProcessToNetwork(net) else ConnectivityManager.setProcessDefaultNetwork(net)
            if (ok) boundNetwork = net
            ok
        } catch (_: Throwable) { false }
    }

    private fun unbindNetwork(): Boolean {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val ok = if (Build.VERSION.SDK_INT >= 23) cm.bindProcessToNetwork(null) else ConnectivityManager.setProcessDefaultNetwork(null)
            boundNetwork = null
            ok
        } catch (_: Throwable) { false }
    }

    private fun openUsbTetherSettings(): Boolean {
        return try {
            val intents = arrayOf(
                android.content.Intent("android.settings.TETHER_SETTINGS"),
                android.content.Intent("android.settings.WIFI_TETHER_SETTINGS"),
                android.content.Intent(android.provider.Settings.ACTION_WIRELESS_SETTINGS)
            )
            var launched = false
            for (i in intents) {
                i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    startActivity(i)
                    launched = true
                    break
                } catch (_: Throwable) {
                    // try next
                }
            }
            launched
        } catch (_: Throwable) { false }
    }
}
