package com.example.audio_streamer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.*
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class PcmService : Service() {
    private val tag = "PcmService"
    private var worker: Thread? = null
    private val running = AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val host = intent?.getStringExtra("host") ?: "127.0.0.1"
        val port = intent?.getIntExtra("port", 7352) ?: 7352
        val sampleRate = intent?.getIntExtra("sampleRate", 48000) ?: 48000
        val channels = intent?.getIntExtra("channels", 2) ?: 2
        val bits = intent?.getIntExtra("bits", 16) ?: 16
        Log.i(tag, "start fg host=$host port=$port sr=$sampleRate ch=$channels")
        startForegroundWithNotification()
        startWorker(host, port, sampleRate, channels, bits)
        return START_STICKY
    }

    override fun onDestroy() {
        stopWorker()
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
            .setContentText("PCM over USB")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
        startForeground(1001, notif)
    }

    private fun startWorker(host: String, port: Int, sampleRate: Int, channels: Int, bits: Int) {
        stopWorker()
        running.set(true)
        worker = Thread {
            var socket: Socket? = null
            var track: AudioTrack? = null
            try {
                socket = Socket()
                socket.tcpNoDelay = true
                socket.connect(InetSocketAddress(host, port), 2000)
                val input: InputStream = socket.getInputStream()

                val channelConfig = if (channels == 1)
                    AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                val audioFormat = if (bits == 16) AudioFormat.ENCODING_PCM_16BIT else AudioFormat.ENCODING_PCM_8BIT
                val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                val desiredBuf = minBuf.coerceAtLeast(sampleRate * channels * (bits / 8) / 33) // ~30ms

                track = if (Build.VERSION.SDK_INT >= 29) {
                    AudioTrack.Builder()
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
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

                track.play()

                val frameBytes = (sampleRate / 100) * channels * (bits / 8) // 10ms
                val buffer = ByteArray(frameBytes)
                while (running.get()) {
                    var read = 0
                    while (read < buffer.size) {
                        val r = input.read(buffer, read, buffer.size - read)
                        if (r <= 0) throw RuntimeException("socket closed")
                        read += r
                    }
                    var written = 0
                    while (written < buffer.size) {
                        val w = track.write(buffer, written, buffer.size - written)
                        if (w < 0) throw RuntimeException("audiotrack write error $w")
                        written += w
                    }
                }
            } catch (t: Throwable) {
                Log.e(tag, "pcm service error", t)
            } finally {
                try { track?.stop() } catch (_: Throwable) {}
                try { track?.release() } catch (_: Throwable) {}
                try { socket?.close() } catch (_: Throwable) {}
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
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
}

