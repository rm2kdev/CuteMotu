#pragma once
#include <atomic>
#include <cstdint>

namespace cute {
// The current SDK requires a zero-timestamp period of at least 10923 frames.
// A returned sample/host pair must also remain fixed until the next boundary;
// refitting a USB clock must not revise a timestamp already given to Core Audio.
inline constexpr uint64_t zeroTimeStampPeriod=16384;
struct ZeroTimeStamp {uint64_t sample=0,host=0,seed=0;};
class ZeroTimeStampCache {
    std::atomic<uint64_t> sequence{0},sample{0},host{0},seed{0};
public:
    bool get(ZeroTimeStamp candidate,ZeroTimeStamp& out){
        for(unsigned attempt=0;attempt<3;attempt++){
            auto seq=sequence.load();if(seq&1)continue;
            ZeroTimeStamp previous{sample.load(),host.load(),seed.load()};
            if(sequence.load()!=seq)continue;
            if(previous.host && candidate.seed==previous.seed && candidate.sample<=previous.sample){out=previous;return true;}
            if(!sequence.compare_exchange_strong(seq,seq+1))continue;
            sample=candidate.sample;host=candidate.host;seed=candidate.seed;sequence.store(seq+2);
            out=candidate;return true;
        }
        return false;
    }
};
}
