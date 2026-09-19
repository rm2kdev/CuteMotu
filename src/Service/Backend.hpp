#pragma once
#include "SharedAudio.hpp"
#include "MOTUDSP.hpp"
#include "MOTUStream.hpp"
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <functional>
#include <memory>
namespace cute {
struct Backend {
    SharedAudio& audio;dispatch_queue_t queue;
    motu::DSPState dsp;motu::DSPMeters meters;
    uint64_t controlEpoch=mach_absolute_time(),ack=0,writes=0,nextTicket=1;uint32_t controlStatus=0;
    std::function<void(const motu::UMP&)> midiInput;
    explicit Backend(SharedAudio& a,dispatch_queue_t q):audio(a),queue(q){}
    virtual ~Backend()=default;
    virtual bool start(uint32_t rate)=0;
    virtual void stop(std::function<void()> done)=0;
    virtual bool setRate(uint32_t rate)=0;
    virtual uint32_t subscribe()=0;
    virtual uint32_t edit(motu::DSPValue value,uint64_t& ticket)=0;
    virtual void midi(const uint32_t* words,size_t count)=0;
    virtual const char* name() const=0;
    virtual uint32_t safeRate()const{return 0;}
    virtual uint32_t blockedRate()const{return 0;}
    virtual bool recoveryPending()const{return false;}
};
std::unique_ptr<Backend> syntheticBackend(SharedAudio&,dispatch_queue_t);
std::unique_ptr<Backend> usbBackend(SharedAudio&,dispatch_queue_t);
}
