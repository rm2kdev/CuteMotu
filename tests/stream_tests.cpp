#include "MOTUStream.hpp"
#include <assert.h>
#include <stdio.h>
#include <math.h>
#include <memory>
#include <thread>
#include <vector>
#include <limits>
#include <string.h>
using namespace motu;
static unsigned checks=0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#x); abort(); } ++checks; } while (0)
static void pcm() {
    CHECK(supportedClock(0x02000100,0x303)); CHECK(supportedClock(0x200,0x303));
    CHECK(!supportedClock(0x100,0x101)); CHECK(!supportedClock(0x100,0x40303));
    CHECK(!supportedClock(0x118,0x303));
    CHECK(floatToPCM(1)==8388607); CHECK(floatToPCM(-1)==-8388608);
    CHECK(floatToPCM(INFINITY)==0); CHECK(floatToPCM(NAN)==0);
    uint8_t output[outputFrameBytes+2]; memset(output,0x55,sizeof(output));
    float out[outputChannels]{}; out[0]=0.5; out[1]=-0.5; out[29]=-1;
    CHECK(packFrame(output+1,outputFrameBytes,out,0x12345678,true,0x90)==Error::none);
    CHECK(output[0]==0x55 && output[outputFrameBytes+1]==0x55);
    const uint8_t golden[]={0x12,0x34,0x56,0x78,0,0,0,0,0,0x90,1,0,0,0,0,0,0,0};
    CHECK(memcmp(output+1,golden,sizeof(golden))==0);
    const uint8_t mainPCM[]={0x40,0,0,0xc0,0,0};
    CHECK(memcmp(output+1+12+10*3,mainPCM,sizeof(mainPCM))==0);
    CHECK(output[100]==0x80 && output[103]==0 && output[104]==0);
    uint8_t input[inputFrameBytes]{}; input[9]=0xf8; input[10]=1;
    input[12]=0x7f; input[13]=0xff; input[14]=0xff; input[15]=0x80; input[111]=0xff; input[112]=0xff; input[113]=0xff;
    float samples[inputChannels]{}; uint8_t byte; bool has;
    CHECK(unpackFrame(input,sizeof(input),samples,byte,has)==Error::none);
    CHECK(samples[0]==8388607.0f/8388608 && samples[1]==-1 && samples[31]==-1.0f/8388608);
    CHECK(has && byte==0xf8); CHECK(unpackFrame(input,sizeof(input)-1,samples,byte,has)==Error::malformed);
}
static void outputRouting() {
    // USB slots are Phones, Analog 1-8, Main, S/PDIF, ADAT A/B. Apps
    // must instead see Main on 1/2 without duplicating it onto other jacks.
    const unsigned expectedWireForHost[]={10,11,2,3,4,5,6,7,8,9,0,1,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29};
    for (unsigned host=0;host<outputChannels;host++) {
        uint8_t packet[outputFrameBytes]; float channels[outputChannels]{};
        channels[host]=0.25f;
        CHECK(packFrame(packet,sizeof(packet),channels,0x12345678,false,0)==Error::none);
        for (unsigned wire=0;wire<outputChannels;wire++)
            CHECK(decode24(packet+pcmOffset+wire*3,true)==(wire==expectedWireForHost[host]?2097152:0));
        CHECK(readBE32(packet)==0x12345678 && packet[9]==0 && packet[10]==0);
        for (unsigned b=pcmOffset+outputChannels*3;b<outputFrameBytes;b++) CHECK(packet[b]==0);
    }
}
static void rings() {
    auto ring=std::make_unique<AudioRing>(); float in[32],out[32];
    for (auto& v:in) v=.25;
    CHECK(!ring->get(0,out,32)); CHECK(out[0]==0);
    ring->put(0,in,32); CHECK(ring->get(0,out,32) && out[31]==.25);
    ring->put(maxRingFrames,in,32); CHECK(!ring->get(0,out,32)); CHECK(ring->get(maxRingFrames,out,32));
    ring->clear(); CHECK(!ring->get(maxRingFrames,out,32));
    std::atomic<bool> done{false},torn{false};
    std::thread writer([&]{ float p[32]; for (uint64_t i=0;i<200000;i++) { for (auto& v:p) v=float(i); ring->put(i,p,32); } done=true; });
    std::thread reader([&]{ float p[32]; uint64_t i=0; while (!done) { if (ring->get(i,p,32)) for (float v:p) if(v!=float(i)) torn=true; i=(i+1)%200000; } });
    writer.join(); reader.join(); CHECK(!torn);
}
static std::vector<UMP> parse(const std::vector<uint8_t>& bytes) {
    MIDIParser p; std::vector<UMP> out; for (auto b:bytes) { UMP u; if(p.feed(b,u)) out.push_back(u); } return out;
}
static void midi() {
    auto m=parse({0x90,60,0xf8,127,61,1,0xc2,7,8,0xf2,1,2,4,5});
    CHECK(m.size()==6); CHECK(m[0].words[0]==0x10f80000); CHECK(m[1].words[0]==0x20903c7f);
    CHECK(m[2].words[0]==0x20903d01); CHECK(m[3].words[0]==0x20c20700); CHECK(m[4].words[0]==0x20c20800); CHECK(m[5].words[0]==0x10f20102);
    auto x=parse({0xf0,1,2,3,4,5,6,0xf8,7,8,0xf7});
    CHECK(x.size()==3 && x[0].words[0]==0x10f80000);
    CHECK(x[1].words[0]==0x30160102 && x[1].words[1]==0x03040506);
    CHECK(x[2].words[0]==0x30320708 && x[2].words[1]==0);
    auto exact=parse({0xf0,1,2,3,4,5,6,0xf7}); CHECK(exact.size()==1 && exact[0].words[0]==0x30060102);
    auto empty=parse({0xf0,0xf7}); CHECK(empty.size()==1 && empty[0].words[0]==0x30000000);
    MIDIQueue q; MIDIEncoder encoder; uint8_t b;
    uint32_t words[]={0x20903c7f,0x20c20700,0x10f80000,0x30060102,0x03040506};
    CHECK(encoder.enqueue(words,5,q)==Error::none);
    const uint8_t expected[]={0x90,60,127,0xc2,7,0xf8,0xf0,1,2,3,4,5,6,0xf7};
    for (uint8_t v:expected) CHECK(q.pop(b) && b==v); CHECK(!q.pop(b));
    uint32_t malformed[]={0x20903c7f,0x20903cff}; CHECK(encoder.enqueue(malformed,2,q)==Error::malformed); CHECK(!q.pop(b));
    uint32_t wrongGroup=0x21903c7f; CHECK(encoder.enqueue(&wrongGroup,1,q)==Error::unsupported);
    uint32_t orphanEnd[]={0x30300000,0}; CHECK(encoder.enqueue(orphanEnd,2,q)==Error::malformed);
    uint32_t start[]={0x30110100,0}; CHECK(encoder.enqueue(start,2,q)==Error::none);
    CHECK(encoder.enqueue(words,1,q)==Error::malformed);
    CHECK(encoder.enqueue(orphanEnd,2,q)==Error::none); q.discard();
    uint8_t full[4096]{}; CHECK(q.push(full,sizeof(full))); CHECK(!q.push(full,1));
    CHECK(encoder.enqueue(words,1,q)==Error::capacity); q.discard(); CHECK(!q.pop(b));
    CHECK(q.push(full,sizeof(full))); MIDIPacer pacer; unsigned sent=0,last=0;
    for (unsigned sample=0;sample<48000;sample++) if (pacer.next(q,b)) { if(sent) CHECK(sample-last>=15); last=sample; sent++; }
    CHECK(sent==3125);
    // Queue wrap and concurrent producer/consumer preserve every byte.
    q.discard(); std::atomic<bool> bad{false};
    std::thread producer([&]{ for(unsigned i=0;i<100000;i++) { uint8_t v=i; while(!q.push(&v,1)) std::this_thread::yield(); } });
    std::thread consumer([&]{ for(unsigned i=0;i<100000;i++) { uint8_t v; while(!q.pop(v)) std::this_thread::yield(); if(v!=uint8_t(i)) bad=true; } });
    producer.join(); consumer.join(); CHECK(!bad);
    // Arbitrary DIN bytes must never emit malformed UMP or overflow parser.
    MIDIParser parser; uint32_t seed=27;
    for(unsigned i=0;i<100000;i++) { seed=1664525*seed+1013904223; UMP u; if(parser.feed(seed>>24,u)) CHECK(u.count==1 || u.count==2); }
}
static void references() {
    USBClockDecoder d; USBClockReference r; uint8_t frame[12]{};
    const uint32_t tick=0x12345678;
    for (unsigned i=0;i<4;i++) { frame[4]=tick>>(8*i); frame[5]=uint8_t((7<<3)|4|i); CHECK(d.feed(frame,12,106,r)==(i==3)); }
    CHECK(r.tick==tick && r.microframe==103);
    d.beginPacket(); frame[5]=5; CHECK(!d.feed(frame,12,106,r));
    for (unsigned i=0;i<4;i++) { frame[4]=tick>>(8*i); frame[5]=uint8_t((12<<3)|4|i); CHECK(d.feed(frame,12,106,r)==(i==3)); }
    CHECK(r.microframe==76);
    StreamClock c; constexpr double hz=24000000;
    for (uint64_t i=0;i<1000;i++) {
        const uint64_t sample=i*8, raw=6000000+sample*1250;
        CHECK(c.reference(uint32_t(raw-7500),100000000+sample*500-3000,hz));
        CHECK(c.observe(uint32_t(raw),1,sample,hz)); // clock-reference mapping overrides inaccurate completion time
        CHECK(c.hostTime(sample+768)==100000000+(sample+768)*500);
    }
    CHECK(c.locked()); CHECK(!c.reference(1,1,hz));
}
static void capturedClock() {
    // Recorded hardware headers, with all audio payloads removed. This catches
    // one-tick hardware quantization and references split across USB packets.
    FILE* f=fopen("tests/fixtures/input-clock-48k.txt","r"); CHECK(f);
    USBClockDecoder decoder; StreamClock clock; uint64_t sample=0; unsigned packets=0;
    char line[1024];
    while (fgets(line,sizeof(line),f)) {
        if (line[0]=='#') continue;
        unsigned long long microframe=0; char hex[193]{};
        CHECK(sscanf(line,"%llu %192s",&microframe,hex)==2 && strlen(hex)==192);
        uint8_t headers[96]{};
        for (unsigned i=0;i<96;i++) { unsigned value=0; CHECK(sscanf(hex+i*2,"%2x",&value)==1); headers[i]=value; }
        uint8_t packet[8*inputFrameBytes]{};
        for (unsigned i=0;i<8;i++) memcpy(packet+i*inputFrameBytes,headers+i*12,12);
        CHECK(inputPacketTimestampsValid(packet,sizeof(packet)));
        decoder.beginPacket();
        for (unsigned i=0;i<8;i++) {
            USBClockReference ref;
            if (decoder.feed(headers+i*12,12,microframe,ref)) CHECK(clock.reference(ref.tick,ref.microframe*3000,24000000));
        }
        if (!clock.hasReference()) continue;
        CHECK(clock.observe(readBE32(headers),microframe*3000,sample,24000000));
        for (unsigned i=0;i<8;i++,sample++) {
            const int32_t delta=int32_t(readBE32(headers+i*12)-clock.timestamp(sample));
            CHECK(delta>=-timestampTolerance && delta<=timestampTolerance);
        }
        packets++;
    }
    fclose(f); CHECK(packets==46 && sample==368 && clock.locked());
    // An entire missing sample must still be rejected.
    CHECK(!clock.observe(clock.timestamp(sample)+ticksPerSample,1,sample,24000000));
}
static void startupClock() {
    uint8_t packet[8*inputFrameBytes]{};
    FILE* f=fopen("tests/fixtures/startup-clock-48k.txt","r"); CHECK(f);
    char line[256]; unsigned packets=0;
    while (fgets(line,sizeof(line),f)) {
        if (line[0]=='#') continue;
        for (unsigned i=0;i<96;i++) {
            unsigned value=0; CHECK(sscanf(line+i*2,"%2x",&value)==1);
            packet[(i/12)*inputFrameBytes+i%12]=value;
        }
        CHECK(!inputPacketTimestampsValid(packet,sizeof(packet))); packets++;
    }
    fclose(f); CHECK(packets==1);
    for (unsigned i=0;i<8;i++) writeBE32(packet+i*inputFrameBytes,0xfffff000u+i*ticksPerSample);
    CHECK(inputPacketTimestampsValid(packet,sizeof(packet))); // wraps within packet
    for (int error : {-1250,-5,-4,4,5,1250}) {
        writeBE32(packet+7*inputFrameBytes,0xfffff000u+7*ticksPerSample+error);
        CHECK(inputPacketTimestampsValid(packet,sizeof(packet))==(error>=-4 && error<=4));
    }
    CHECK(!inputPacketTimestampsValid(nullptr,sizeof(packet)));
    CHECK(!inputPacketTimestampsValid(packet,0));
    CHECK(!inputPacketTimestampsValid(packet,sizeof(packet)-1));
    CHECK(!inputPacketTimestampsValid(packet,sizeof(packet)+inputFrameBytes));
    StreamClock clock;
    for (uint64_t i=0;i<32;i++) {
        CHECK(clock.reference(uint32_t(6000000+i*10000),100000000+i*4000,24000000));
        CHECK(clock.observe(uint32_t(6000000+i*10000),1,i*8,24000000));
    }
    CHECK(clock.locked()); clock.reset(); CHECK(!clock.locked() && !clock.hasReference());
    // Reacquisition requires a new complete sequence, even after a large
    // startup timestamp discontinuity. Sample indices remain monotonic.
    for (uint64_t i=0;i<32;i++) {
        CHECK(clock.reference(uint32_t(300000000+i*10000),300000000+i*4000,24000000));
        CHECK(clock.observe(uint32_t(300000000+i*10000),1,256+i*8,24000000));
        CHECK(clock.locked()==(i==31));
    }
    CHECK(!clock.observe(clock.timestamp(512)+ticksPerSample,1,512,24000000));
}
static void scheduler() {
    CHECK(presentationLead*ticksPerSample==4*7500);
    StreamClock c; uint32_t count;
    CHECK(planOutputPacket(c,1000000,0,count)==Error::unsupported);
    for(uint64_t sample=0;sample<=256;sample+=8) {
        CHECK(c.reference(uint32_t(6000000+sample*1250-7500),100000000+sample*500-3000,24000000));
        CHECK(c.observe(uint32_t(6000000+sample*1250),1,sample,24000000));
    }
    uint64_t next=presentationLead; unsigned packets=0;
    for(unsigned microframe=1;microframe<=8000;microframe++) {
        CHECK(planOutputPacket(c,100000000+presentationLead*500+uint64_t(microframe)*3000,next,count)==Error::none);
        CHECK(count==0 || count==8); CHECK(count*outputFrameBytes<=960);
        next+=count; packets+=count?1:0;
    }
    CHECK(next==presentationLead+48000 && packets==6000);
    CHECK(planOutputPacket(c,c.hostTime(next+16),next,count)==Error::capacity);
}
static void clocks() {
    StreamClock c; const uint32_t base=0xffff0000; const double hz=24000000;
    for(uint64_t sample=0;sample<48000;sample+=6) {
        uint64_t host=100000000+sample*500;
        CHECK(c.observe(base+uint32_t(sample*1250),host,sample,hz));
        CHECK(c.timestamp(sample+768)==uint32_t(base+(sample+768)*1250));
        CHECK(c.hostTime(sample+768)==host+768*500);
    }
    CHECK(!c.locked()); CHECK(c.reference(1,100000000,hz)); CHECK(c.reference(7501,100003000,hz)); CHECK(c.locked()); CHECK(!c.observe(0,0,50000,hz));
    c.reset(); CHECK(!c.locked());
    CHECK(c.observe(0,1000000,0,hz)); CHECK(!c.observe(1250,1000500,2,hz));
    for (int ppm : {-100,100}) {
        c.reset(); const double ticks=500.0/(1+ppm/1e6);
        for(uint64_t s=0;s<48000*10;s+=6) CHECK(c.observe(uint32_t(s*1250),1000000+uint64_t(s*ticks),s,hz));
        CHECK(!c.locked());
        CHECK(llabs(int64_t(c.hostTime(480000))-int64_t(1000000+480000*ticks))<3);
    }
}
static void busClocks() {
    // Reproduce a USB oscillator drifting relative to mach time. A single
    // nominal-rate anchor accumulates 36 ms error in ten minutes at 60 ppm.
    for (int ppm : {-100,60,100}) {
        USBHostClock c; const uint64_t baseFrame=1234567,baseHost=1000000000;
        const double period=3000.0/(1+ppm/1e6);
        auto measured=[&](uint64_t frame) { return baseHost+uint64_t(double(frame-baseFrame)*period); };
        CHECK(c.hostTime(baseFrame)==0);
        CHECK(c.reference(baseFrame,baseHost,24000000));
        for (uint64_t frame=baseFrame+800;frame<baseFrame+8000*600;frame+=800) {
            const auto before=c.hostTime(frame);
            CHECK(c.reference(frame,measured(frame),24000000));
            CHECK(c.hostTime(frame)==before);
            // Historical input references and future queued output boundaries
            // must use the same correlation, including non-frame-aligned refs.
            for (int offset : {-256,-1,0,1,256,800}) {
                const auto probe=uint64_t(int64_t(frame)+offset);
                const auto tolerance=frame-baseFrame<80000?400:12;
                CHECK(llabs(int64_t(c.hostTime(probe))-int64_t(measured(probe)))<=tolerance);
            }
        }
        CHECK(!c.reference(baseFrame,baseHost,24000000));
        CHECK(!c.reference(baseFrame+8000*600,0,24000000));
    }
    // Exercise the actual downstream frequency gate across every refresh, not
    // just the bus correlation in isolation (regression for build 19).
    USBHostClock bus; StreamClock device;
    const uint64_t start=1000000000,first=10000;
    const double period=3000.0/(1+60/1e6);
    CHECK(bus.reference(first,start,24000000));
    for (uint64_t f=first+1;f<first+8000*30;f++) {
        const auto realHost=start+uint64_t((f-first)*period);
        if ((f-first)%800==0) CHECK(bus.reference(f,realHost,24000000));
        const auto raw=uint32_t(double(realHost-start)*2.5);
        CHECK(device.reference(raw,bus.hostTime(f),24000000));
    }
    // Build 21: a refresh rewrote the past while an input completion was
    // delayed, shortening a 7,500-device-tick interval to 2,690 host ticks.
    // Include controller timestamp jitter, delayed callbacks and tick wrap.
    for (unsigned lag : {1,32,128,256}) {
        USBHostClock delayedBus; StreamClock delayedDevice;
        CHECK(delayedBus.reference(first,start,24000000));
        for (uint64_t f=first+1;f<first+8000*90;f++) {
            const auto host=delayedBus.hostTime(f);
            if ((f-first)%800==0) {
                const auto update=f+lag;
                const int jitter=((f-first)/800)%2?2400:-2400;
                CHECK(delayedBus.reference(update,start+uint64_t((update-first)*period)+jitter,24000000));
                CHECK(delayedBus.hostTime(f)==host);
            }
            const auto raw=uint32_t(0xffff0000u+uint64_t(double(f-first)*period*2.5));
            CHECK(delayedDevice.reference(raw,delayedBus.hostTime(f),24000000));
        }
    }
    // Controller references can themselves be older than already processed
    // input or queued output. Applying a correction at that old frame would
    // still change a correlation which has already been used.
    for (unsigned age : {32,256,4000}) {
        USBHostClock cached; StreamClock hardware;
        CHECK(cached.reference(first,start,24000000));
        for (uint64_t f=first+age+1;f<first+8000*30;f++) {
            const auto queued=cached.hostTime(f+128);
            const auto prior=cached.hostTime(f-1);
            if ((f-first)%800==0) {
                const auto ref=f-age;
                CHECK(cached.reference(ref,start+uint64_t((ref-first)*period),24000000));
                CHECK(cached.hostTime(f+128)==queued);
                CHECK(cached.hostTime(f-1)==prior);
            }
            const auto raw=uint32_t(double(f-first)*period*2.5);
            CHECK(hardware.reference(raw,cached.hostTime(f),24000000));
        }
    }
}
static void sampleRates() {
    CHECK(!profileForRate(0) && !profileForRate(32000) && !profileForRate(96001));
    CHECK(!profileForClock(0x600) && !profileForClock(0x101));
    const unsigned inputs[]={32,32,22,22,12,12},outputs[]={30,30,20,20,10,10};
    const unsigned wireInputs[][32]={
        {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33},
        {0,1,2,3,4,5,6,7,8,9,12,13,14,15,18,19,20,21,22,23,24,25},
        {0,1,2,3,4,5,6,7,8,9,12,13}
    };
    const unsigned wireOutputs[][30]={
        {10,11,2,3,4,5,6,7,8,9,0,1,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29},
        {10,11,2,3,4,5,6,7,8,9,12,13,14,15,16,17,18,19,20,21},
        {10,11,2,3,4,5,6,7,8,9}
    };
    for(unsigned index=0;index<6;index++) {
        const auto& p=rateProfiles[index];const unsigned family=index/2;
        CHECK(profileForRate(p.rate)==&p && profileForClock(0x02000000|(index<<8))==&p);
        CHECK(p.inputs==inputs[index] && p.outputs==outputs[index]);
        CHECK((rateClockWord(0xa2000100,p)&0xff00)==index<<8);
        CHECK((rateClockWord(0xa2000100,p)&0xff000000)==0xa0000000);
        CHECK(p.packetSamples*p.inputBytes<=p.inputCapacity && p.packetSamples*p.outputBytes<=p.outputCapacity);
        CHECK(p.ringPeriod()<=maxRingFrames && p.ringPeriod()>p.rate/20);
        uint8_t frame[122]{};float samples[32]{};uint8_t midi=0;bool has=false;
        for(unsigned wire=0;wire<(p.inputBytes-12)/3;wire++)encode24((wire+1)*8192,frame+1+12+wire*3,true);
        CHECK(unpackFrame(frame+1,p.inputBytes,samples,midi,has,p)==Error::none);
        for(unsigned c=0;c<p.inputs;c++)CHECK(samples[c]==float(wireInputs[family][c]+1)/1024);
        for(unsigned channel=0;channel<p.outputs;channel++) {
            memset(samples,0,sizeof(samples));samples[channel]=.25f;memset(frame,0x55,sizeof(frame));
            CHECK(packFrame(frame+1,p.outputBytes,samples,123,true,0xf8,p)==Error::none);
            CHECK(frame[0]==0x55 && frame[p.outputBytes+1]==0x55 && frame[10]==0xf8 && frame[11]==1);
            for(unsigned wire=0;wire<(p.outputBytes-12)/3;wire++)CHECK(decode24(frame+1+12+wire*3,true)==(wire==wireOutputs[family][channel]?2097152:0));
        }
        StreamClock clock;clock.configure(p);
        constexpr uint64_t baseHost=100000000,baseTick=0xffff0000u;
        auto tick=[&](uint64_t s){return uint32_t(baseTick+llround(double(s)*deviceClockHz/p.rate));};
        auto host=[&](uint64_t s){return baseHost+uint64_t(llround(double(s)*24000000/p.rate));};
        // Fractional periods, wraparound, and long-running sample clock phase.
        for(uint64_t packet=0;packet<40000;packet++) {
            const auto sample=packet*p.packetSamples;
            CHECK(clock.reference(tick(sample),host(sample),24000000));
            CHECK(clock.observe(tick(sample),host(sample),sample,24000000));
            CHECK(abs(int32_t(clock.timestamp(sample+50000)-tick(sample+50000)))<=1);
            CHECK(llabs(int64_t(clock.hostTime(sample+50000))-int64_t(host(sample+50000)))<=4);
        }
        uint8_t packet[1920]{};
        for(unsigned i=0;i<p.packetSamples;i++)writeBE32(packet+i*p.inputBytes,tick(i));
        CHECK(inputPacketTimestampsValid(packet,p.packetSamples*p.inputBytes,p));
        writeBE32(packet+(p.packetSamples-1)*p.inputBytes,tick(p.packetSamples));
        CHECK(!inputPacketTimestampsValid(packet,p.packetSamples*p.inputBytes,p));
        uint64_t next=50000;const auto start=clock.hostTime(next);unsigned packets=0;
        for(unsigned microframe=1;microframe<=8000;microframe++) {
            uint32_t frames=0;
            CHECK(planOutputPacket(clock,start+uint64_t(microframe)*3000,next,frames)==Error::none);
            CHECK(frames==0 || frames==p.packetSamples);next+=frames;packets+=frames?1:0;
        }
        CHECK(next-50000>=p.rate && next-50000<p.rate+p.packetSamples);
        CHECK(packets>=5500 && packets<=6001);
        MIDIQueue queue;MIDIPacer pacer;pacer.configure(p.rate);uint8_t bytes[4096]{};CHECK(queue.push(bytes,sizeof(bytes)));
        unsigned sent=0,last=0;for(unsigned sample=0;sample<p.rate;sample++)if(pacer.next(queue,midi)){
            if(sent)CHECK(sample-last>=p.rate/3125);last=sample;sent++;
        }
        CHECK(sent==3125);
    }
}
int main() {
    { uint8_t packet[8*inputFrameBytes]{};const uint32_t origin=752108236;uint32_t result=0;
      for(unsigned i=0;i<8;i++)writeBE32(packet+i*inputFrameBytes,origin+i*ticksPerSample);
      writeBE32(packet,origin-597);
      CHECK(!inputPacketTimestampsValid(packet,sizeof(packet)));
      CHECK(recoverFirstTimestamp(packet,sizeof(packet),origin,result));CHECK(result==origin);
      CHECK(!recoverFirstTimestamp(packet,sizeof(packet),origin+100,result));
      writeBE32(packet+3*inputFrameBytes,origin+3*ticksPerSample+100);
      CHECK(!recoverFirstTimestamp(packet,sizeof(packet),origin,result));
    }
 sampleRates(); pcm(); outputRouting(); rings(); midi(); references(); capturedClock(); startupClock(); scheduler(); clocks(); busClocks(); printf("PASS: %u streaming assertions (PCM, rings, clocks, MIDI, concurrency)\n",checks); }
