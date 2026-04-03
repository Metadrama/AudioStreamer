#include "AudioEngine.h"
#include <algorithm>

// JNI
static AudioEngine *gAudioEngine = nullptr;

AudioEngine::AudioEngine() {
    mBuffer.reserve(48000 * 2);
}

AudioEngine::~AudioEngine() {
    stop();
}

oboe::DataCallbackResult AudioEngine::onAudioReady(oboe::AudioStream *oboeStream, 
                                                  void *audioData, 
                                                  int32_t numFrames) {
    int16_t *outputData = static_cast<int16_t *>(audioData);
    int32_t channelCount = oboeStream->getChannelCount();
    int32_t numSamples = numFrames * channelCount;
    
    // 1. Try to pull from Jitter Buffer (UDP Receiver)
    int64_t remoteSamples = 0;
    int32_t pulled = mUdpReceiver.getNextFrame(outputData, numSamples, remoteSamples);
    
    if (pulled > 0) {
        mFramesPlayed += (pulled / channelCount);
        mLastRemoteSamples = remoteSamples;
        
        if (pulled < numSamples) {
            // Padding if we didn't get enough
            std::fill(outputData + pulled, outputData + numSamples, 0);
        }
        return oboe::DataCallbackResult::Continue;
    }
    
    // 2. Fallback to Legacy Buffer (TCP/JNI push)
    std::lock_guard<std::mutex> lock(mBufferMutex);
    if (mBuffer.size() >= (size_t)numSamples) {
        std::copy(mBuffer.begin(), mBuffer.begin() + numSamples, outputData);
        mBuffer.erase(mBuffer.begin(), mBuffer.begin() + numSamples);
        mFramesPlayed += numFrames;
        return oboe::DataCallbackResult::Continue;
    }

    // 3. Silence on Underflow
    std::fill(outputData, outputData + numSamples, 0);
    return oboe::DataCallbackResult::Continue;
}

void AudioEngine::start() {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output)
           ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
           ->setSharingMode(oboe::SharingMode::Exclusive)
           ->setFormat(oboe::AudioFormat::I16)
           ->setChannelCount(oboe::ChannelCount::Stereo)
           ->setSampleRate(mSampleRate)
           ->setDataCallback(this);

    oboe::Result result = builder.openStream(mStream);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open stream: %s", oboe::convertToText(result));
        return;
    }
    mStream->requestStart();
}

void AudioEngine::stop() {
    if (mStream) {
        mStream->stop();
        mStream->close();
        mStream.reset();
    }
}

void AudioEngine::setSampleRate(int32_t sampleRate) { mSampleRate = sampleRate; }

void AudioEngine::pushData(int64_t remoteSamples, const int16_t* data, int32_t numSamples) {
    std::lock_guard<std::mutex> lock(mBufferMutex);
    mBuffer.insert(mBuffer.end(), data, data + numSamples);
    mLastRemoteSamples = remoteSamples;
}

void AudioEngine::pushUdpPacket(const uint8_t* buffer, size_t size) {
    mUdpReceiver.pushPacket(buffer, size);
}

// --- JNI REGISTRATION ---

void nativeInit(JNIEnv *env, jobject thiz) {
    if (gAudioEngine == nullptr) {
        gAudioEngine = new AudioEngine();
        LOGD("Native AudioEngine initialized");
    }
}

void nativeStart(JNIEnv *env, jobject thiz) {
    if (gAudioEngine) gAudioEngine->start();
}

void nativeStop(JNIEnv *env, jobject thiz) {
    if (gAudioEngine) gAudioEngine->stop();
}

void nativePushData(JNIEnv *env, jobject thiz, jlong remoteSamples, jobject data, jint size) {
    if (gAudioEngine) {
        void *body = env->GetDirectBufferAddress(data);
        if (body) gAudioEngine->pushData(remoteSamples, static_cast<const int16_t*>(body), size / 2);
    }
}

void nativePushUdpPacket(JNIEnv *env, jobject thiz, jobject data, jint size) {
    if (gAudioEngine) {
        void *body = env->GetDirectBufferAddress(data);
        if (body) gAudioEngine->pushUdpPacket(static_cast<const uint8_t*>(body), (size_t)size);
    }
}

static JNINativeMethod gMethods[] = {
    {"nativeInit", "()V", (void*)nativeInit},
    {"nativeStart", "()V", (void*)nativeStart},
    {"nativeStop", "()V", (void*)nativeStop},
    {"nativePushData", "(JLjava/nio/ByteBuffer;I)V", (void*)nativePushData},
    {"nativePushUdpPacket", "(Ljava/nio/ByteBuffer;I)V", (void*)nativePushUdpPacket}
};

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    if (vm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

    jclass clazz = env->FindClass("com/example/audio_streamer/NativeAudioEngine");
    if (clazz == nullptr) return JNI_ERR;

    if (env->RegisterNatives(clazz, gMethods, sizeof(gMethods) / sizeof(gMethods[0])) < 0) {
        return JNI_ERR;
    }

    return JNI_VERSION_1_6;
}
