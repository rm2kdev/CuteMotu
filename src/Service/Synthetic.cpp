#include "Backend.hpp"
#include "Client.hpp"
#include <mach/mach_time.h>
namespace cute {
class Synthetic final:public Backend {
    motu::MIDIEncoder encoder;motu::MIDIQueue bytes;motu::MIDIParser parser;dispatch_source_t timer=nullptr;uint32_t currentRate=48000;uint64_t origin=0,frame=0;double ticks=ticksPerSecond();
    void reset(uint32_t rate){currentRate=rate;audio.online=0;audio.epoch.fetch_add(1);audio.rate=rate;origin=mach_absolute_time();frame=0;audio.inputFrames=0;audio.outputFrames=0;audio.clock(0,origin,ticks/rate);audio.heartbeat=origin;audio.online=1;}
    void tick(){auto now=mach_absolute_time();auto rate=currentRate;uint64_t target=uint64_t(double(now-origin)*rate/ticks);
        // Scheduling pauses never cause unbounded catch-up or replay.
        if(target>frame+maxIOFrames){frame=target;audio.errors.fetch_add(1);}
        const auto* p=motu::profileForRate(rate);auto epoch=audio.epoch.load();
        while(frame<target){float out[maxChannels]{},in[maxChannels]{};
            if(audio.audioActive.load())audio.output.get(frame,epoch,out,p->outputs);
            for(unsigned c=0;c<p->outputs;c++)in[c]=out[c];
            audio.input.put(frame,epoch,in,p->inputs);frame++;
        }
        audio.clock(frame,origin+uint64_t(frame*ticks/rate),ticks/rate);audio.inputFrames=frame;audio.outputFrames=frame;audio.heartbeat=now;
    }
public:
    using Backend::Backend;
    bool start(uint32_t rate) override {if(!motu::profileForRate(rate))return false;reset(rate);
        timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
        dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_MSEC,100000);
        dispatch_source_set_event_handler(timer,^{tick();});dispatch_resume(timer);return true;
    }
    void stop(std::function<void()> done) override {audio.online=0;if(timer){dispatch_source_cancel(timer);dispatch_release(timer);timer=nullptr;}done();}
    bool setRate(uint32_t r) override {if(!motu::profileForRate(r))return false;reset(r);return true;}
    // Synthetic mode never impersonates a hardware DSP dump.
    uint32_t subscribe() override {return 0xe00002c7;}
    uint32_t edit(motu::DSPValue,uint64_t&) override {return 0xe00002c7;}
    void midi(const uint32_t* words,size_t count) override {
        if(encoder.enqueue(words,count,bytes)!=motu::Error::none)return;uint8_t b;motu::UMP m;while(bytes.pop(b))if(parser.feed(b,m) && midiInput)midiInput(m);
    }
    const char* name() const override{return "synthetic-loopback";}
};
std::unique_ptr<Backend> syntheticBackend(SharedAudio& a,dispatch_queue_t q){return std::make_unique<Synthetic>(a,q);}
}
