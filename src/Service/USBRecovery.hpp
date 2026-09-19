#pragma once
#include <algorithm>
#include <cstdint>
namespace cute {
// Queue-confined recovery policy. A failed high-rate stream falls back to the
// last successful 44.1/48 kHz rate. Do not repeat a saved failing rate on every
// Core Audio re-publication. A different successful base rate or a physical
// reconnect permits another deliberate attempt.
class USBRecovery {
    uint32_t safe=48000,blocked=0;unsigned failures=0;
    uint64_t device=0,due=0;bool waiting=false;
public:
    uint32_t safeRate()const{return safe;}
    uint32_t blockedRate()const{return blocked;}
    bool pending()const{return waiting;}
    bool accepts(uint32_t rate)const{return rate!=blocked;}
    void connected(uint64_t id){if(id && device && id!=device)blocked=0;if(id)device=id;}
    void online(uint32_t rate){
        if(rate<=48000){if(rate!=safe)blocked=0;safe=rate;}
        failures=0;waiting=false;
    }
    void failed(uint32_t rate,uint64_t now,uint64_t ticksPerSecond){
        if(rate>48000)blocked=rate;
        const unsigned seconds=std::min(30u,1u<<std::min(failures,5u));
        failures=std::min(failures+1,6u);due=now+seconds*ticksPerSecond;waiting=true;
    }
    uint32_t take(uint64_t now){if(!waiting || now<due)return 0;waiting=false;return safe;}
    void cancel(){waiting=false;}
};
}
