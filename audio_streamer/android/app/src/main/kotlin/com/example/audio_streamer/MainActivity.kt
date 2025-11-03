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
    private var pcmClient: PcmClient? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startPcm" -> {
                        val host = call.argument<String>("host") ?: "127.0.0.1"
                        val port = call.argument<Int>("port") ?: 7352
                        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                        val channels = call.argument<Int>("channels") ?: 2
                        val bits = call.argument<Int>("bits") ?: 16
                        Log.i("PcmClient", "startPcm host=$host port=$port sr=$sampleRate ch=$channels bits=$bits")
                        stopClient()
                        pcmClient = PcmClient(host, port, sampleRate, channels, bits)
                        pcmClient!!.start()
                        result.success(null)
                    }
                    "stopPcm" -> {
                        stopClient()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun stopClient() {
        pcmClient?.stop()
        pcmClient = null
    }

    override fun onDestroy() {
        stopClient()
        super.onDestroy()
    }
}

class PcmClient(
    private val host: String,
    private val port: Int,
    private val sampleRate: Int,
    private val channels: Int,
    private val bits: Int
) {
    private val tag = "PcmClient"
    private var thread: Thread? = null
    private val running = AtomicBoolean(false)

    fun start() {
        if (running.getAndSet(true)) return
        thread = Thread { runLoop() }.apply {
            name = "pcm-client"
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    fun stop() {
        running.set(false)
        thread?.interrupt()
        thread = null
    }

    private fun runLoop() {
        var socket: Socket? = null
        var track: AudioTrack? = null
        try {
            socket = Socket()
            socket.tcpNoDelay = true
            Log.i(tag, "connecting to $host:$port")
            socket.connect(InetSocketAddress(host, port), 2000)
            val input: InputStream = socket.getInputStream()

            val channelConfig = if (channels == 1)
                AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)
            val desiredBuf = minBuf.coerceAtLeast(sampleRate * channels * 2 / 50) // ~20ms

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

            Log.i(tag, "audiotrack play")
            track.play()

            val frameBytes = (sampleRate / 100) * channels * 2 // 10ms
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
            Log.e(tag, "pcm loop error", t)
        } finally {
            try { track?.stop() } catch (_: Throwable) {}
            try { track?.release() } catch (_: Throwable) {}
            try { socket?.close() } catch (_: Throwable) {}
        }
    }
}
