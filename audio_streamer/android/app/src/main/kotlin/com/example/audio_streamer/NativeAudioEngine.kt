package com.example.audio_streamer

import android.util.Log
import java.nio.ByteBuffer

class NativeAudioEngine {
    companion object {
        init {
            try {
                System.loadLibrary("audio_streamer_native")
                Log.d("NativeAudioEngine", "Native library loaded successfully")
            } catch (e: Exception) {
                Log.e("NativeAudioEngine", "Error loading native library: ${e.message}")
            }
        }
    }

    external fun nativeInit()
    external fun nativeStart()
    external fun nativeStop()
    external fun nativePushData(remoteSamples: Long, data: ByteBuffer, size: Int)

    external fun nativePushUdpPacket(data: ByteBuffer, size: Int)

    fun init() = nativeInit()
    fun start() = nativeStart()
    fun stop() = nativeStop()
    fun pushData(remoteSamples: Long, data: ByteBuffer, size: Int) = nativePushData(remoteSamples, data, size)
    fun pushUdpPacket(data: ByteBuffer, size: Int) = nativePushUdpPacket(data, size)
}
