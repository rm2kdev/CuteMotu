#pragma once
#include <stdint.h>

namespace motu {
struct StreamProfile {
    uint32_t rate, clockCode, multiplier;
    uint32_t inputs, outputs, inputBytes, outputBytes, packetSamples;
    uint32_t alternate, inputCapacity, outputCapacity;
    constexpr uint32_t inputPacketBytes() const { return inputBytes*packetSamples; }
    constexpr uint32_t ringPeriod() const { return 4096*multiplier; }
    constexpr uint32_t inputWire(uint32_t channel) const {
        // Input wire slots 16/17 are padding. Reverb return slots 10/11 are
        // unavailable above 48 kHz; the stereo return remains at 12/13.
        return multiplier==1 ? (channel<16?channel:channel+2) :
            (channel<10?channel:channel<14?channel+2:channel+4);
    }
    constexpr uint32_t outputWire(uint32_t channel) const {
        // Preserve Main-first host order. Phones' wire slots stay reserved
        // above 48 kHz even though the independent Phones stream disappears.
        return channel<2 ? channel+10 : channel<10 ? channel :
            multiplier==1 ? (channel<12?channel-10:channel) : channel+2;
    }
};
inline constexpr StreamProfile rateProfiles[] = {
    {44100,  0,1,32,30,120,108, 8,1, 960, 960},
    {48000,  1,1,32,30,120,108, 8,1, 960, 960},
    {88200,  2,2,22,20, 96, 84,16,4,1920,1536},
    {96000,  3,2,22,20, 96, 84,16,4,1920,1536},
    {176400, 4,4,12,10, 60, 48,32,4,1920,1536},
    {192000, 5,4,12,10, 60, 48,32,4,1920,1536}
};
inline constexpr const StreamProfile* profileForRate(uint32_t rate) {
    for (const auto& p:rateProfiles) if(p.rate==rate)return &p;
    return nullptr;
}
inline constexpr const StreamProfile& defaultProfile() { return rateProfiles[1]; }
inline constexpr const StreamProfile* profileForClock(uint32_t word) {
    const auto code=(word>>8)&255;
    return (word&255)==0 && code<6 ? &rateProfiles[code]:nullptr;
}
inline constexpr uint32_t rateClockWord(uint32_t current,const StreamProfile& profile) {
    return (current&~0x0200ff00u)|(profile.clockCode<<8);
}
}
