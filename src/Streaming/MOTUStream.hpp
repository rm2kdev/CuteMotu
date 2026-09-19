#pragma once
#include "MOTUProtocol.hpp"
#include "MOTURate.hpp"
#include <atomic>
#include <stddef.h>
#include <stdint.h>

namespace motu {
constexpr uint32_t sampleRate = 48000;
constexpr uint32_t ringFrames = 4096, maxRingFrames = 16384;
constexpr uint32_t inputChannels = 32, outputChannels = 30;
// Incoming stride is measured from live USB captures, including padding.
constexpr uint32_t inputFrameBytes = 120, outputFrameBytes = 108;
static_assert(8 * outputFrameBytes <= 960, "Eight samples must fit alternate 1");
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<uint32_t>::is_always_lock_free, "Realtime rings require lock-free atomics");
constexpr uint32_t pcmOffset = 12, midiDataOffset = 9, midiFlagOffset = 10;
constexpr uint32_t clockRegister = 0xf0000b14, opticalRegister = 0xf0000c94;
constexpr uint32_t streamRegister = 0xf0000b00;
constexpr uint32_t deviceClockHz = 60000000, ticksPerSample = 1250;
constexpr int32_t timestampTolerance = 4;
// Device presentation delay is independent of the host's USB queue depth.
// The hybrid vendor path adds four 125-us cycles (30,000 device ticks).
constexpr uint32_t presentationLead = 24; // 0.5 ms at 48 kHz.

bool supportedClock(uint32_t clock, uint32_t optical);
int32_t floatToPCM(float value);
void writeBE32(uint8_t* bytes, uint32_t value);

// Atomic payload and generation tags prevent torn frames, including when a HAL
// client falls behind and USB overwrites a slot. Each ring has one writer.
class AudioRing {
public:
    void clear(); // Only with the writer quiesced.
    void put(uint64_t frame, const float* samples, uint32_t channels);
    bool get(uint64_t frame, float* samples, uint32_t channels) const;
private:
    struct Frame { std::atomic<uint64_t> tag{0}; std::atomic<uint32_t> data[32]{}; } frames_[maxRingFrames];
};

struct UMP { uint32_t words[2]{}; uint8_t count = 0; };
// Single-producer/single-consumer, all-or-nothing publication of a MIDI message.
class MIDIQueue {
public:
    bool push(const uint8_t* bytes, uint32_t count);
    bool pop(uint8_t& byte);
    void discard(); // Consumer only; producer may remain active.
private:
    uint8_t bytes_[4096]{};
    std::atomic<uint32_t> read_{0}, write_{0};
};
class MIDIParser {
public:
    bool feed(uint8_t byte, UMP& message);
    void reset();
private:
    bool emitSysEx(uint8_t kind, UMP& message);
    uint8_t status_=0, running_=0, data_[6]{}, used_=0, need_=0;
    bool sysex_=false, continued_=false;
};
// Stateful SysEx validation; consumes a complete batch or publishes nothing.
class MIDIEncoder {
public:
    Error enqueue(const uint32_t* words, size_t count, MIDIQueue& queue);
    void reset() { sysex_ = false; }
private:
    bool sysex_ = false;
};
class MIDIPacer {
public:
    bool next(MIDIQueue& queue, uint8_t& byte);
    void configure(uint32_t rate) { rate_=rate; phase_=rate; }
private:
    uint32_t rate_ = sampleRate, phase_ = sampleRate;
};

struct USBClockReference { uint32_t tick=0; uint64_t microframe=0; };
// The USB controller's oscillator is independent of mach_absolute_time. Refresh
// this correlation from ReferenceMicroframe instead of extrapolating forever
// at exactly 8,000 microframes per host second.
class USBHostClock {
public:
    bool reference(uint64_t microframe, uint64_t host, double hostTicksPerSecond);
    uint64_t hostTime(uint64_t microframe) const;
private:
    uint64_t firstFrame_=0, firstHost_=0, frame_=0, host_=0, observedHost_=0;
    double ticksPerMicroframe_=0;
    struct Segment { uint64_t frame=0, host=0; double period=0; };
    // Retain 1.6 seconds of correlation history for delayed USB callbacks.
    Segment segments_[16]{};
    unsigned segmentCount_=0;
    mutable uint64_t mappedThrough_=0;
};
class USBClockDecoder {
public:
    bool feed(const uint8_t* frame, size_t length, uint64_t microframe, USBClockReference& result);
    void beginPacket() { used_=0; }
private:
    uint8_t bytes_[4]{}; uint8_t used_=0;
};

// Sample timestamp clock. USB completion host times are in mach absolute ticks.
// Need a monotonic hardware timestamp sequence and measured host slope before
// publication. All methods run on the USB serial queue.
class StreamClock {
public:
    void configure(const StreamProfile& profile) { profile_=&profile; reset(); }
    const StreamProfile& profile() const { return *profile_; }
    bool observe(uint32_t raw, uint64_t hostTime, uint64_t sampleIndex, double hostTicksPerSecond);
    bool reference(uint32_t raw, uint64_t hostTime, double hostTicksPerSecond);
    bool hasReference() const { return references_ > 0; }
    bool locked() const { return observations_ >= 32 && references_ >= 2; }
    uint32_t timestamp(uint64_t sampleIndex) const;
    uint64_t hostTime(uint64_t sampleIndex) const;
    void reset();
private:
    const StreamProfile* profile_=&defaultProfile();
    TimestampUnwrapper unwrap_;
    uint64_t originTick_=0, originSample_=0, anchorSample_=0, anchorHost_=0;
    uint64_t firstHost_=0, firstSample_=0, lastSample_=0;
    double hostPerSample_=0;
    uint32_t observations_=0, references_=0, referenceRaw_=0;
    uint64_t referenceHost_=0;
    double hostPerTick_=0;
};
Error planOutputPacket(const StreamClock& clock, uint64_t boundaryHost, uint64_t nextSample, uint32_t& frames);
// Validate the whole packet before using any clock fields or publishing PCM.
bool recoverFirstTimestamp(const uint8_t* packet,size_t bytes,uint32_t expected,uint32_t& recovered, const StreamProfile& profile=defaultProfile());
bool inputPacketTimestampsValid(const uint8_t* packet, size_t size, const StreamProfile& profile=defaultProfile());
Error unpackFrame(const uint8_t* frame, size_t size, float* samples, uint8_t& midi, bool& hasMIDI, const StreamProfile& profile=defaultProfile());
Error packFrame(uint8_t* frame, size_t size, const float* samples, uint32_t timestamp, bool hasMIDI, uint8_t midi, const StreamProfile& profile=defaultProfile());
}
