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
        startForegroundWithNotification()
        acquireLocks()
        startWorker(host, port, sampleRate, channels, bits, targetMs, prefillFrames, queueCapacity)
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
            .build()
        startForeground(1001, notif)
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
        worker = Thread {
            while (running.get()) {
                var socket: Socket? = null
                var track: AudioTrack? = null
                try {
                    MainActivity.sendPcmEvent("connecting")
                    socket = Socket()
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    socket.receiveBufferSize = 256 * 1024
                    socket.sendBufferSize = 256 * 1024
                    socket.connect(InetSocketAddress(host, port), 1500)
                    // Use blocking reads for steady pacing; service handles reconnects on failure
                    try { socket.soTimeout = 0 } catch (_: Throwable) {}
                    val input: InputStream = socket.getInputStream()

                    val channelConfig = if (channels == 1)
                        AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                    val audioFormat = if (bits == 16) AudioFormat.ENCODING_PCM_16BIT else AudioFormat.ENCODING_PCM_8BIT
                    val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                    // Ultra-low-latency path: keep device buffer close to targetMs, but never below platform minimum
                    val targetBytes = sampleRate * channels * (bits / 8) * targetMs / 1000
                    val desiredBuf = maxOf(minBuf, targetBytes)

                    track = if (Build.VERSION.SDK_INT >= 29) {
                        AudioTrack.Builder()
                            .setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                    .setFlags(AudioAttributes.FLAG_LOW_LATENCY)
                                    .build()
                            )
                            .setAudioFormat(
                                AudioFormat.Builder()
                                    .setSampleRate(sampleRate)
                                    .setEncoding(audioFormat)
                                    .setChannelMask(channelConfig)
                                    .build()
                            )
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .setBufferSizeInBytes(desiredBuf)
                            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                            .build()
                    } else {
                        @Suppress("DEPRECATION")
                        AudioTrack(
                            AudioManager.STREAM_MUSIC,
                            sampleRate,
                            channelConfig,
                            audioFormat,
                            desiredBuf,
                            AudioTrack.MODE_STREAM
                        )
                    }
                    // Implement jitter buffer with pooled frames + remote sample timestamps to absorb jitter and correct drift
                    val bytesPerSample = channels * (bits / 8)
                    val frameBytes = (sampleRate / 100) * bytesPerSample // 10ms frames
                    val samplesPerFrame = frameBytes / bytesPerSample
                    val capacity = queueCapacity
                    val queue = ArrayBlockingQueue<Frame>(capacity)
                    fun take(timeoutMs: Long): Frame? = queue.poll(timeoutMs, TimeUnit.MILLISECONDS)

                    val framePool = ArrayDeque<Frame>(capacity * 2)
                    val headerBuf = ByteArray(8)

                    fun obtainFrame(): Frame = synchronized(framePool) {
                        if (framePool.isEmpty()) {
                            Frame(ByteArray(frameBytes), 0L)
                        } else {
                            val f = framePool.removeFirst()
                            if (f.data.size != frameBytes) {
                                f.data = ByteArray(frameBytes)
                            }
                            f
                        }
                    }

                    fun recycleFrame(frame: Frame?) {
                        if (frame == null) return
                        if (frame.data.size != frameBytes) return
                        synchronized(framePool) {
                            if (framePool.size < capacity * 3) {
                                framePool.addLast(frame)
                            }
                        }
                    }

                    // Reader loop
                    val reader = Thread {
                        try {
                            try { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) } catch (_: Throwable) {}
                            while (running.get()) {
                                var headerRead = 0
                                while (headerRead < headerBuf.size && running.get()) {
                                    val r = try { input.read(headerBuf, headerRead, headerBuf.size - headerRead) } catch (ste: SocketTimeoutException) { -1 }
                                    if (r <= 0) throw RuntimeException("socket closed or read timeout")
                                    headerRead += r
                                }
                                if (!running.get()) break
                                val remoteSamples = readLongLE(headerBuf)

                                val frame = obtainFrame()
                                frame.remoteSamples = remoteSamples
                                var off = 0
                                val buf = frame.data
                                while (off < frameBytes && running.get()) {
                                    val r = try { input.read(buf, off, frameBytes - off) } catch (ste: SocketTimeoutException) { -1 }
                                    if (r <= 0) throw RuntimeException("socket closed or read timeout")
                                    off += r
                                }
                                if (!running.get()) {
                                    recycleFrame(frame)
                                    break
                                }
                                if (!queue.offer(frame)) {
                                    val dropped = queue.poll()
                                    recycleFrame(dropped)
                                    queue.offer(frame)
                                }
                            }
                        } catch (_: Throwable) {
                            // exit
                        }
                    }.apply { name = "pcm-reader"; priority = Thread.NORM_PRIORITY + 1; isDaemon = true; start() }

                    // Writer loop with prefill, drift correction, and underrun detection
                    var sentConnected = false
                    var last: Frame? = null
                    val prefill = prefillFrames
                    var okPrefill = 0
                    while (running.get() && okPrefill < prefill) {
                        val frame = take(400) ?: break
                        recycleFrame(last)
                        last = frame
                        okPrefill++
                    }
                    if (okPrefill == 0 || last == null) throw RuntimeException("no data during prefill")

                    track.play()
                    var playbackBaseRemote = last!!.remoteSamples
                    var lastSpeed = 1.0f
                    var lastSpeedChangeNs = 0L
                    if (!sentConnected) {
                        sentConnected = true
                        MainActivity.sendPcmEvent("connected")
                    }

                    var emptyPolls = 0
                    val zeroBuf = ByteArray(frameBytes)
                    var latestRemote = playbackBaseRemote
                    while (running.get()) {
                        try { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) } catch (_: Throwable) {}
                        val frame = take(120) ?: last
                        if (frame == null) continue
                        if (frame === last) {
                            emptyPolls++
                            if (emptyPolls >= 64) throw RuntimeException("pcm underrun timeout")
                        } else {
                            emptyPolls = 0
                        }

                        // Gap concealment: prefer last-frame repeat over silence to avoid clicks at ultra-low latency
                        val data = if (frame === last) (last?.data ?: zeroBuf) else frame.data
                        var off = 0
                        while (off < data.size && running.get()) {
                            val remaining = data.size - off
                            val w = if (Build.VERSION.SDK_INT >= 23) {
                                track.write(data, off, remaining, AudioTrack.WRITE_BLOCKING)
                            } else {
                                track.write(data, off, remaining)
                            }
                            if (w < 0) throw RuntimeException("audiotrack write error $w")
                            off += w
                        }

                        if (frame.remoteSamples < playbackBaseRemote) {
                            playbackBaseRemote = frame.remoteSamples
                        }
                        latestRemote = frame.remoteSamples + samplesPerFrame.toLong()
                        val baseRemote = playbackBaseRemote
                        val played = track.playbackHeadPosition.toLong()
                        val queueSamples = latestRemote - baseRemote - played
                        val targetSamples = prefill.toLong() * samplesPerFrame.toLong()
                        // For ultra-low targets (<= ~20 ms), avoid frequent speed changes which can be audible.
                        val allowSpeedAdjust = prefill > 2
                        // Wider threshold and smaller adjustment to reduce churn
                        val threshold = samplesPerFrame.toLong() * 4L // ~4 frames
                        val desiredSpeed = if (!allowSpeedAdjust) 1.0f else when {
                            queueSamples - targetSamples > threshold -> 1.005f
                            queueSamples - targetSamples < -threshold -> 0.995f
                            else -> 1.0f
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && allowSpeedAdjust) {
                            if (abs(desiredSpeed - lastSpeed) >= 0.005f) {
                                val now = try { System.nanoTime() } catch (_: Throwable) { 0L }
                                // Minimum interval between speed changes to add hysteresis (~250 ms)
                                val okToChange = (now == 0L) || (now - lastSpeedChangeNs > 250_000_000L)
                                if (okToChange) {
                                    try {
                                        val params = track.playbackParams
                                        if (abs(params.speed - desiredSpeed) >= 0.005f) {
                                            track.playbackParams = params.setSpeed(desiredSpeed)
                                        }
                                        lastSpeed = desiredSpeed
                                        if (now != 0L) lastSpeedChangeNs = now
                                    } catch (_: Throwable) {}
                                }
                            }
                        }

                        if (frame !== last) {
                            recycleFrame(last)
                            last = frame
                        }
                    }
                } catch (t: Throwable) {
                    Log.e(tag, "pcm service error", t)
                    MainActivity.sendPcmEvent("disconnected", t.message)
                    // brief backoff before reconnect
                    try { Thread.sleep(300) } catch (_: Throwable) {}
                } finally {
                    try { /* reader */ } catch (_: Throwable) {}
                    try { track?.stop() } catch (_: Throwable) {}
                    try { track?.release() } catch (_: Throwable) {}
                    try { socket?.close() } catch (_: Throwable) {}
                    // Continue loop if still running; stopForeground is handled after loop exits
                }
            }
            // exiting worker loop
            stopForeground(STOP_FOREGROUND_REMOVE)
            releaseLocks()
            MainActivity.sendPcmEvent("stopped")
            stopSelf()
        }.apply {
            name = "pcm-service"
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
