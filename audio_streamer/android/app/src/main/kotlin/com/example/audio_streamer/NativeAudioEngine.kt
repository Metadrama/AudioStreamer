package com.example.audio_streamer

import android.util.Log
import java.nio.ByteBuffer

class NativeAudioEngine {
    companion object {
        var isLoaded = false
        init {
            try {
                System.loadLibrary("audio_streamer_native")
                Log.d("NativeAudioEngine", "Native library loaded successfully")
                isLoaded = true
            } catch (e: Throwable) {
                Log.e("NativeAudioEngine", "Error loading native library: ${e.message}", e)
            }
        }
    }

    external fun nativeInit()
    external fun nativeStart()
    external fun nativeStop()
    external fun nativePushData(remoteSamples: Long, data: ByteBuffer, size: Int)
    external fun nativePushUdpPacket(data: ByteBuffer, size: Int)

    fun init() {
        if (!isLoaded) {
            Log.e("NativeAudioEngine", "Cannot call init: Library not loaded")
            return
        }
        try {
            nativeInit()
        } catch (e: Throwable) {
            Log.e("NativeAudioEngine", "nativeInit failed", e)
        }
    }

    fun start() {
        if (isLoaded) try { nativeStart() } catch (e: Throwable) { Log.e("NativeAudioEngine", "nativeStart failed", e) }
    }

    fun stop() {
        if (isLoaded) try { nativeStop() } catch (e: Throwable) { Log.e("NativeAudioEngine", "nativeStop failed", e) }
    }

    fun pushData(remoteSamples: Long, data: ByteBuffer, size: Int) {
        if (isLoaded) try { nativePushData(remoteSamples, data, size) } catch (e: Throwable) { Log.e("NativeAudioEngine", "nativePushData failed", e) }
    }

    fun pushUdpPacket(data: ByteBuffer, size: Int) {
        if (isLoaded) try { nativePushUdpPacket(data, size) } catch (e: Throwable) { Log.e("NativeAudioEngine", "nativePushUdpPacket failed", e) }
    }
}

