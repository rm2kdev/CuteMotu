#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>
namespace motu {
// Control callbacks publish targets. Only the audio I/O thread advances the ramp.
class PlaybackVolume {
    std::atomic<float> level{1.0f};
    std::atomic<bool> enabled{false}, muted{false};
    float current=1.0f, target=1.0f, step=0;
    uint32_t remaining=0, rampLength=240;
public:
    static constexpr uint32_t rampFrames=240; // Default 5 ms at 48 kHz.
    void setSampleRate(uint32_t rate) { rampLength=rate/200; reset(); }
    static_assert(std::atomic<float>::is_always_lock_free && std::atomic<bool>::is_always_lock_free);
    void setEnabled(bool value) { enabled.store(value,std::memory_order_relaxed); }
    bool isEnabled() const { return enabled.load(std::memory_order_relaxed); }
    void setMuted(bool value) { muted.store(value,std::memory_order_relaxed); }
    bool setDecibels(float db) {
        if (!std::isfinite(db) || db < -96 || db > 0) return false;
        level.store(db<=-96 ? 0.0f : std::pow(10.0f,db/20.0f),std::memory_order_relaxed);return true;
    }
    float requestedGain() const {
        return !enabled.load(std::memory_order_relaxed) ? 1.0f : muted.load(std::memory_order_relaxed) ? 0.0f : level.load(std::memory_order_relaxed);
    }
    void beginBuffer() {
        const float next=requestedGain();
        if (next!=target) {target=next;remaining=rampLength;step=(target-current)/rampLength;}
    }
    void reset() { current=target=requestedGain();remaining=0;step=0; }
    void apply(float* frame) {
        if (remaining && !--remaining) current=target;
        else if (remaining) current+=step;
        if (current==0) {frame[0]=0;frame[1]=0;}
        else if (current!=1) {frame[0]*=current;frame[1]*=current;}
    }
};
}
