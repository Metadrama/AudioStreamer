#include "UdpReceiver.h"
#include <cstring>
#include <algorithm>
#include <android/log.h>

#define TAG "UdpReceiver"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

UdpReceiver::UdpReceiver() {}
UdpReceiver::~UdpReceiver() {}

void UdpReceiver::pushPacket(const uint8_t* buffer, size_t size) {
    if (size < 14) return;

    UdpPacket pkt;
    // Header format: [8b samples][2b seq][2b size][2b flags]
    std::memcpy(&pkt.remoteSamples, buffer, 8);
    std::memcpy(&pkt.seq, buffer + 8, 2);
    std::memcpy(&pkt.size, buffer + 10, 2);
    std::memcpy(&pkt.flags, buffer + 12, 2);

    pkt.data.resize(pkt.size / 2);
    std::memcpy(pkt.data.data(), buffer + 14, pkt.size);

    std::lock_guard<std::mutex> lock(mMutex);
    
    if (!mInitialized) {
        mNextSeq = pkt.seq;
        mInitialized = true;
        LOGI("JitterBuffer initialized with seq %d", mNextSeq);
    }

    // Ignore very old packets (too far before current seq)
    if (pkt.seq < mNextSeq && (uint16_t)(mNextSeq - pkt.seq) < 30000) return;

    mBuffer[pkt.seq] = std::move(pkt);
    
    // Simple FEC: If we just received a parity packet, see if we can recover its group
    if (pkt.flags == 1) {
        attemptFec(pkt.seq);
    }
}

void UdpReceiver::attemptFec(uint16_t paritySeq) {
    // Current group: (paritySeq-4) to (paritySeq-1)? 
    // In our C# implementation, we used (lastSeq + 10000) for parity.
    // Let's assume the group is simply the 4 packets preceding the parity packet.
    // Re-check our C# logic: parity packet seq was (seq + 10000).
    // Let's use a simpler mapping: if paritySeq >= 10000, it's parity for (paritySeq-10003) to (paritySeq-10000)
    
    if (paritySeq < 10000) return;
    uint16_t base = paritySeq - 10000 - 3; // The seq of the first packet in the 4-pack
    
    std::vector<uint16_t> missing;
    for (int i = 0; i < 4; i++) {
        uint16_t s = base + i;
        if (mBuffer.find(s) == mBuffer.end()) {
            missing.push_back(s);
        }
    }

    if (missing.size() == 1) {
        // Recover exactly one missing packet!
        uint16_t m = missing[0];
        const auto& parity = mBuffer[paritySeq];
        
        UdpPacket recovered;
        recovered.seq = m;
        recovered.size = parity.size;
        recovered.flags = 0;
        recovered.data.resize(parity.data.size(), 0);
        
        // XOR with parity
        for (size_t i = 0; i < parity.data.size(); i++) {
            recovered.data[i] = parity.data[i];
        }
        
        // XOR with other 3 received packets
        for (int i = 0; i < 4; i++) {
            uint16_t s = base + i;
            if (s == m) continue;
            auto it_p = mBuffer.find(s);
            if (it_p == mBuffer.end()) continue; // Should not happen given missing.size() == 1
            const auto& p = it_p->second;
            size_t minLen = std::min(recovered.data.size(), p.data.size());
            for (size_t j = 0; j < minLen; j++) {
                recovered.data[j] ^= p.data[j];
            }
        }
        
        LOGI("FEC: Recovered packet %d", m);
        mBuffer[m] = std::move(recovered);
    }
}

int32_t UdpReceiver::getNextFrame(int16_t* outData, int32_t numSamples, int64_t& outRemoteSamples) {
    std::lock_guard<std::mutex> lock(mMutex);
    
    if (mBuffer.empty()) return 0;

    auto it = mBuffer.find(mNextSeq);
    if (it != mBuffer.end()) {
        const auto& pkt = it->second;
        int32_t copyCount = std::min((int32_t)pkt.data.size(), numSamples);
        std::memcpy(outData, pkt.data.data(), copyCount * sizeof(int16_t));
        outRemoteSamples = pkt.remoteSamples;
        
        mBuffer.erase(it);
        mNextSeq++;
        return copyCount;
    }

    // Skip ahead if we're falling too far behind or stuck on a missing packet
    if (mBuffer.begin()->first > mNextSeq + 10) {
        mNextSeq = mBuffer.begin()->first;
        LOGI("JitterBuffer: Skipped ahead to %d", mNextSeq);
    }

    return 0;
}
