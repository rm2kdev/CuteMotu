#include "AnalysisBridge.h"
#include "AnalysisTap.hpp"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <memory>
#include <vector>

namespace {
constexpr UInt32 maxFrames = 4096;
struct Capture {
    AudioUnit unit = nullptr;
    UInt32 channels = 0;
    std::vector<float> scratch;
    AnalysisTap tap;
    std::atomic<int32_t> error{0};
    ~Capture() {
        if (unit) {
            // Stop/uninitialize dispose the AU's I/O thread before storage dies.
            AudioOutputUnitStop(unit);
            AudioUnitUninitialize(unit);
            AudioComponentInstanceDispose(unit);
        }
    }
    static OSStatus input(void* context, AudioUnitRenderActionFlags* flags,
                          const AudioTimeStamp* time, UInt32, UInt32 frames, AudioBufferList*) {
        auto& c = *static_cast<Capture*>(context);
        const auto selection = c.tap.selection();
        if (frames > maxFrames) { c.error.store(kAudioUnitErr_TooManyFramesToProcess); return noErr; }
        AudioBufferList buffers{1, {{c.channels, UInt32(frames * c.channels * sizeof(float)), c.scratch.data()}}};
        const OSStatus status = AudioUnitRender(c.unit, flags, time, 1, frames, &buffers);
        if (status != noErr) { c.error.store(status, std::memory_order_relaxed); return noErr; }
        if (*flags & kAudioUnitRenderAction_OutputIsSilence)
            std::fill_n(c.scratch.data(), frames * c.channels, 0.0f);
        c.tap.push(c.scratch.data(), frames, c.channels, selection);
        return noErr;
    }
};
}
void* analysisCaptureOpen(uint32_t device, uint32_t left, uint32_t right, int32_t* error) {
    auto c = std::make_unique<Capture>();
    auto check = [error](OSStatus status) { if (error) *error = status; return status == noErr; };
    AudioComponentDescription description{kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    auto component = AudioComponentFindNext(nullptr, &description);
    if (!component) { if (error) *error = kAudio_ParamError; return nullptr; }
    if (!check(AudioComponentInstanceNew(component, &c->unit))) return nullptr;
    UInt32 enabled = 1, disabled = 0;
    if (!check(AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled))) ||
        !check(AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled))) ||
        !check(AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device)))) return nullptr;
    AudioStreamBasicDescription hardware{};
    UInt32 bytes = sizeof(hardware);
    if (!check(AudioUnitGetProperty(c->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &bytes))) return nullptr;
    c->channels = hardware.mChannelsPerFrame;
    if (c->channels < 1 || c->channels > 32 || left >= c->channels || right >= c->channels || hardware.mSampleRate < 32000 || hardware.mSampleRate > 192000) {
        if (error) *error = kAudio_ParamError;
        return nullptr;
    }
    c->tap.select(left, right);
    c->scratch.resize(maxFrames * c->channels);
    AudioStreamBasicDescription format{hardware.mSampleRate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
        UInt32(sizeof(float) * c->channels), 1, UInt32(sizeof(float) * c->channels), c->channels, 32, 0};
    AURenderCallbackStruct callback{Capture::input, c.get()};
    if (!check(AudioUnitSetProperty(c->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames))) ||
        !check(AudioUnitSetProperty(c->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format))) ||
        !check(AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback))) ||
        !check(AudioUnitInitialize(c->unit)) || !check(AudioOutputUnitStart(c->unit))) return nullptr;
    return c.release();
}
void analysisCaptureClose(void* capture) { delete static_cast<Capture*>(capture); }
int analysisCaptureSelect(void* capture, uint32_t left, uint32_t right) {
    if (!capture) return 0;
    auto& c = *static_cast<Capture*>(capture);
    if (left >= c.channels || right >= c.channels) return 0;
    c.tap.select(left, right);
    return 1;
}
uint32_t analysisCaptureRead(void* capture, float* left, float* right, uint32_t capacity, uint64_t* dropped, int32_t* error) {
    if (!capture || !left || !right) return 0;
    auto& c = *static_cast<Capture*>(capture);
    if (dropped) *dropped = c.tap.dropped();
    if (error) *error = c.error.load(std::memory_order_relaxed);
    return c.tap.read(left, right, capacity);
}
