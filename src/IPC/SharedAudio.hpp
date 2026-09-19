#pragma once
#include "MOTURate.hpp"
#include <atomic>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <cstddef>
#include <limits>
namespace cute {
inline constexpr char serviceName[]="org.cutemix.usbaudio.service";
inline constexpr char deviceUID[]="org.cutemix.usbaudio.prototype";
constexpr uint32_t abiVersion=1, maxChannels=32, ringSize=16384, maxIOFrames=4096;
constexpr uint64_t magic=0x435554454d495831ull;
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<uint32_t>::is_always_lock_free);
// Atomic words and double-checked tags make overwrite safe across processes.
// One producer per ring. Tags include epoch so reconnects cannot replay audio.
struct alignas(64) Ring {
    struct Frame {std::atomic<uint64_t> tag{0};std::atomic<uint32_t> epoch{0};std::atomic<uint32_t> samples[maxChannels]{};};
    Frame frames[ringSize];
    void put(uint64_t index,uint32_t generation,const float* data,uint32_t channels) {
        if(channels>maxChannels || index>=UINT64_MAX/2)return;
        auto& f=frames[index%ringSize];f.tag.store(index*2+1,std::memory_order_seq_cst);
        f.epoch.store(generation,std::memory_order_seq_cst);
        for(uint32_t c=0;c<channels;c++){float v=std::isfinite(data[c])?data[c]:0;uint32_t b;memcpy(&b,&v,4);f.samples[c].store(b,std::memory_order_seq_cst);}
        f.tag.store(index*2+2,std::memory_order_seq_cst);
    }
    bool get(uint64_t index,uint32_t generation,float* data,uint32_t channels) const {
        if(channels>maxChannels || index>=UINT64_MAX/2)return false;
        auto& f=frames[index%ringSize];const auto t=f.tag.load(std::memory_order_seq_cst);
        bool valid=t==index*2+2 && f.epoch.load(std::memory_order_seq_cst)==generation;
        if(valid)for(uint32_t c=0;c<channels;c++){auto b=f.samples[c].load(std::memory_order_seq_cst);memcpy(data+c,&b,4);if(!std::isfinite(data[c]))data[c]=0;}
        valid=valid && f.tag.load(std::memory_order_seq_cst)==t && f.epoch.load(std::memory_order_seq_cst)==generation;
        if(!valid)memset(data,0,channels*sizeof(float));return valid;
    }
};
struct Clock {uint64_t sample=0,host=0,periodBits=0;uint32_t epoch=0,rate=0;};
struct alignas(64) SharedAudio {
    uint64_t signature=magic;uint32_t version=abiVersion,bytes=sizeof(SharedAudio);
    uint32_t capacity=ringSize,channels=maxChannels;uint64_t reserved=0;
    std::atomic<uint32_t> online{0},rate{48000},epoch{1},audioActive{0};
    std::atomic<uint64_t> heartbeat{0},clockSequence{0},sample{0},host{0},periodBits{0};
    std::atomic<uint64_t> inputFrames{0},outputFrames{0},underruns{0},errors{0};
    Ring input,output;
    void clock(uint64_t s,uint64_t h,double ticksPerSample) {
        uint64_t bits;memcpy(&bits,&ticksPerSample,8);
        clockSequence.fetch_add(1,std::memory_order_seq_cst);
        sample.store(s,std::memory_order_seq_cst);host.store(h,std::memory_order_seq_cst);periodBits.store(bits,std::memory_order_seq_cst);
        clockSequence.fetch_add(1,std::memory_order_seq_cst);
    }
    bool snapshot(Clock& c) const {
        for(unsigned i=0;i<3;i++) {auto a=clockSequence.load(std::memory_order_seq_cst);if(a&1)continue;
            c={sample.load(),host.load(),periodBits.load(),epoch.load(),rate.load()};
            if(a==clockSequence.load(std::memory_order_seq_cst))return true;
        }return false;
    }
    bool fresh(uint64_t now,double ticksPerSecond) const {
        auto beat=heartbeat.load(std::memory_order_acquire);
        return online.load(std::memory_order_acquire)==1 && beat && now>=beat && double(now-beat)<ticksPerSecond/4;
    }
};
inline bool validate(const void* p,size_t size) {
    if(!p || size!=((sizeof(SharedAudio)+16383)&~size_t(16383)) || uintptr_t(p)%alignof(SharedAudio))return false;
    const auto& s=*static_cast<const SharedAudio*>(p);
    return s.signature==magic && s.version==abiVersion && s.bytes==sizeof(SharedAudio) && s.capacity==ringSize && s.channels==maxChannels && !s.reserved && motu::profileForRate(s.rate.load());
}
inline double clockPeriod(const Clock& c){double value;memcpy(&value,&c.periodBits,8);return value;}
inline bool sampleIndex(double time,uint32_t count,uint64_t& result) {
    if(!std::isfinite(time) || time<0 || time>double(UINT64_MAX/4) || count>maxIOFrames || std::floor(time)!=time)return false;
    result=uint64_t(time);return true;
}
}
