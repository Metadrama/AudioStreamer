#ifndef AUDIO_ENGINE_H
#define AUDIO_ENGINE_H

#include <oboe/Oboe.h>
#include <atomic>
#include <mutex>
#include <vector>
#include <jni.h>
#include <android/log.h>
#include "UdpReceiver.h"

#define LOG_TAG "AudioEngine"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

class AudioEngine : public oboe::AudioStreamDataCallback {
public:
    AudioEngine();
    virtual ~AudioEngine();

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream *oboeStream, 
                                          void *audioData, 
                                          int32_t numFrames) override;

    void start();
    void stop();
    void setSampleRate(int32_t sampleRate);
    void pushData(int64_t remoteSamples, const int16_t* data, int32_t numSamples);
    void pushUdpPacket(const uint8_t* buffer, size_t size);

private:
    std::shared_ptr<oboe::AudioStream> mStream;
    int32_t mSampleRate = 48000;
    
    std::mutex mBufferMutex;
    std::vector<int16_t> mBuffer;
    
    std::atomic<float> mCurrentSpeed{1.0f};
    std::atomic<int64_t> mFramesPlayed{0};
    std::atomic<int64_t> mLastRemoteSamples{0};

    UdpReceiver mUdpReceiver;
};

#endif
