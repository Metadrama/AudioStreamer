package com.example.audio_streamer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.*
import android.media.PlaybackParams
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.net.wifi.WifiManager
import android.os.PowerManager
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import android.os.Process

class PcmService : Service() {
    private val tag = "PcmService"
    private var worker: Thread? = null
    private val running = AtomicBoolean(false)
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private val nativeEngine = NativeAudioEngine()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val host = intent?.getStringExtra("host") ?: "127.0.0.1"
        val port = intent?.getIntExtra("port", 7352) ?: 7352
        val sampleRate = intent?.getIntExtra("sampleRate", 48000) ?: 48000
        val channels = intent?.getIntExtra("channels", 2) ?: 2
        val bits = intent?.getIntExtra("bits", 16) ?: 16
        val targetMs = intent?.getIntExtra("targetMs", 40) ?: 40
        val prefillFrames = intent?.getIntExtra("prefill", 6) ?: 6
        val queueCapacity = intent?.getIntExtra("capacity", 16) ?: 16
        Log.i(tag, "start fg host=$host port=$port sr=$sampleRate ch=$channels")
        
        try {
            startForegroundWithNotification()
            acquireLocks()
            nativeEngine.init()
            startWorker(host, port, sampleRate, channels, bits, targetMs, prefillFrames, queueCapacity)
        } catch (e: Throwable) {
            Log.e(tag, "Failed to start PcmService", e)
            MainActivity.sendPcmEvent("error", "Failed to start service: ${e.message}")
            stopSelf()
        }
        
        return START_STICKY
    }

    override fun onDestroy() {
        stopWorker()
        releaseLocks()
        super.onDestroy()
    }

    private fun startForegroundWithNotification() {
        val channelId = "pcm_stream"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val chan = NotificationChannel(channelId, "PCM Stream", NotificationManager.IMPORTANCE_LOW)
            nm.createNotificationChannel(chan)
        }
        val notif: Notification = Notification.Builder(this, channelId)
            .setContentTitle("Audio streaming")
            .setContentText("PCM stream")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .apply {
                if (Build.VERSION.SDK_INT >= 34) {
                    setCategory(Notification.CATEGORY_SERVICE)
                }
            }
            .build()
            
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1001, notif, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(1001, notif)
        }
    }

    private fun acquireLocks() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (wakeLock?.isHeld != true) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "audio_streamer:pcm").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Throwable) {}
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            if (wifiLock?.isHeld != true) {
                @Suppress("DEPRECATION")
                val mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifiLock = wm.createWifiLock(mode, "audio_streamer:pcm").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Throwable) {}
    }

    private fun releaseLocks() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Throwable) {}
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Throwable) {}
        wakeLock = null
        wifiLock = null
    }

    private fun startWorker(host: String, port: Int, sampleRate: Int, channels: Int, bits: Int, targetMs: Int, prefillFrames: Int, queueCapacity: Int) {
        stopWorker()
        running.set(true)

        // UDP Receiver Thread
        Thread {
            var udpSocket: java.net.DatagramSocket? = null
            try {
                udpSocket = java.net.DatagramSocket(7354)
                udpSocket.receiveBufferSize = 1024 * 1024
                val buffer = java.nio.ByteBuffer.allocateDirect(2048)
                val packet = java.net.DatagramPacket(ByteArray(2048), 2048)
                
                while (running.get()) {
                    udpSocket.receive(packet)
                    buffer.clear()
                    if (packet.length <= buffer.capacity()) {
                        buffer.put(packet.data, 0, packet.length)
                        buffer.flip()
                        nativeEngine.pushUdpPacket(buffer, packet.length)
                    }
                }
            } catch (e: Exception) {
                Log.e(tag, "UDP error: ${e.message}")
            } finally {
                try { udpSocket?.close() } catch (_: Exception) {}
            }
        }.apply { name = "pcm-udp-receiver"; start() }

        worker = Thread {
            while (running.get()) {
                var socket: Socket? = null
                try {
                    MainActivity.sendPcmEvent("connecting")
                    socket = Socket()
                    socket.tcpNoDelay = true
                    socket.connect(InetSocketAddress(host, port), 1500)
                    val input: InputStream = socket.getInputStream()

                    nativeEngine.start()
                    MainActivity.sendPcmEvent("connected")

                    val frameBytes = (sampleRate / 100) * channels * (bits / 8)
                    val headerBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    val dataBuf = java.nio.ByteBuffer.allocateDirect(frameBytes)
                    val channel = java.nio.channels.Channels.newChannel(input)

                    while (running.get()) {
                        headerBuf.clear()
                        while (headerBuf.hasRemaining() && running.get()) {
                            if (channel.read(headerBuf) <= 0) throw RuntimeException("socket closed")
                        }
                        headerBuf.flip()
                        val remoteSamples = headerBuf.getLong()

                        dataBuf.clear()
                        while (dataBuf.hasRemaining() && running.get()) {
                            if (channel.read(dataBuf) <= 0) throw RuntimeException("socket closed")
                        }
                        dataBuf.flip()
                        
                        nativeEngine.pushData(remoteSamples, dataBuf, frameBytes)
                    }
                } catch (t: Throwable) {
                    Log.e(tag, "pcm service error", t)
                    MainActivity.sendPcmEvent("disconnected", t.message)
                    try { Thread.sleep(300) } catch (_: Throwable) {}
                } finally {
                    nativeEngine.stop()
                    try { socket?.close() } catch (_: Throwable) {}
                }
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            releaseLocks()
            MainActivity.sendPcmEvent("stopped")
            stopSelf()
        }.apply {
            name = "pcm-native-service"
            priority = Thread.NORM_PRIORITY + 1
            start()
        }
    }

    private fun stopWorker() {
        running.set(false)
        worker?.interrupt()
        worker = null
    }

    private fun readLongLE(buf: ByteArray): Long {
        var value = 0L
        var shift = 0
        while (shift < 64 && shift / 8 < buf.size) {
            val b = buf[shift / 8]
            value = value or ((b.toLong() and 0xFFL) shl shift)
            shift += 8
        }
        return value
    }

    private class Frame(var data: ByteArray, var remoteSamples: Long)
}
