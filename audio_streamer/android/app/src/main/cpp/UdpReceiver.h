#ifndef UDP_RECEIVER_H
#define UDP_RECEIVER_H

#include <vector>
#include <map>
#include <mutex>
#include <cstdint>
#include <deque>

struct UdpPacket {
    int64_t remoteSamples;
    uint16_t seq;
    uint16_t size;
    uint16_t flags;
    std::vector<int16_t> data;
};

class UdpReceiver {
public:
    UdpReceiver();
    ~UdpReceiver();

    void pushPacket(const uint8_t* buffer, size_t size);
    int32_t getNextFrame(int16_t* outData, int32_t numSamples, int64_t& outRemoteSamples);

private:
    std::map<uint16_t, UdpPacket> mBuffer;
    std::mutex mMutex;
    uint16_t mNextSeq = 0;
    bool mInitialized = false;

    void attemptFec(uint16_t seq);
};

#endif
