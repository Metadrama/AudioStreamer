#include "AudioEngine.h"
#include <algorithm>

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
    
    // 1. Try to pull from Jitter Buffer (UDP Receiver)
    int64_t remoteSamples = 0;
    int32_t pulled = mUdpReceiver.getNextFrame(outputData, numFrames, remoteSamples);
    
    if (pulled > 0) {
        mFramesPlayed += (pulled / channelCount);
        mLastRemoteSamples = remoteSamples;
        
        if (pulled < numFrames) {
            // Padding if we didn't get enough
            std::fill(outputData + (pulled * channelCount), outputData + (numFrames * channelCount), 0);
        }
        return oboe::DataCallbackResult::Continue;
    }
    
    // 2. Fallback to Legacy Buffer (TCP/JNI push)
    std::lock_guard<std::mutex> lock(mBufferMutex);
    if (mBuffer.size() >= numFrames * channelCount) {
        std::copy(mBuffer.begin(), mBuffer.begin() + (numFrames * channelCount), outputData);
        mBuffer.erase(mBuffer.begin(), mBuffer.begin() + (numFrames * channelCount));
        mFramesPlayed += numFrames;
        return oboe::DataCallbackResult::Continue;
    }

    // 3. Silence on Underflow
    std::fill(outputData, outputData + (numFrames * channelCount), 0);
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
    if (result != oboe::Result::OK) return;
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

// JNI
static AudioEngine *gAudioEngine = nullptr;

extern "C" {
    JNIEXPORT void JNICALL Java_com_example_audio_streamer_NativeAudioEngine_nativeInit(JNIEnv *env, jobject thiz) {
        if (gAudioEngine == nullptr) gAudioEngine = new AudioEngine();
    }
    JNIEXPORT void JNICALL Java_com_example_audio_streamer_NativeAudioEngine_nativeStart(JNIEnv *env, jobject thiz) {
        if (gAudioEngine) gAudioEngine->start();
    }
    JNIEXPORT void JNICALL Java_com_example_audio_streamer_NativeAudioEngine_nativeStop(JNIEnv *env, jobject thiz) {
        if (gAudioEngine) gAudioEngine->stop();
    }
    JNIEXPORT void JNICALL Java_com_example_audio_streamer_NativeAudioEngine_nativePushData(JNIEnv *env, jobject thiz, jlong remoteSamples, jobject data, jint size) {
        if (gAudioEngine) {
            void *body = env->GetDirectBufferAddress(data);
            if (body) gAudioEngine->pushData(remoteSamples, static_cast<const int16_t*>(body), size / 2);
        }
    }
    JNIEXPORT void JNICALL Java_com_example_audio_streamer_NativeAudioEngine_nativePushUdpPacket(JNIEnv *env, jobject thiz, jobject data, jint size) {
        if (gAudioEngine) {
            void *body = env->GetDirectBufferAddress(data);
            if (body) gAudioEngine->pushUdpPacket(static_cast<const uint8_t*>(body), (size_t)size);
        }
    }
}
