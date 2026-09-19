#include "MOTUStream.hpp"
#include <string.h>
#include <math.h>
namespace motu {
bool supportedClock(uint32_t clock, uint32_t optical) {
    // Internal clock, both optical banks configured as ADAT.
    return profileForClock(clock)!=nullptr && (optical & 0x00550303) == 0x00000303;
}
void writeBE32(uint8_t* p, uint32_t v) { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
int32_t floatToPCM(float v) {
    if (!isfinite(v)) return 0;
    if (v >= 1) return 8388607;
    if (v <= -1) return -8388608;
    return static_cast<int32_t>(v * 8388608.0f);
}
void AudioRing::clear() { for (auto& f : frames_) f.tag.store(0, std::memory_order_release); }
void AudioRing::put(uint64_t frame, const float* p, uint32_t ch) {
    if (!p || ch>32 || frame>=(UINT64_MAX/2-1)) return;
    auto& f=frames_[frame%maxRingFrames];
    f.tag.store((frame+1)*2+1, std::memory_order_seq_cst);
    for (uint32_t c=0;c<ch;c++) { uint32_t v; memcpy(&v,p+c,4); f.data[c].store(v,std::memory_order_seq_cst); }
    f.tag.store((frame+1)*2,std::memory_order_seq_cst);
}
bool AudioRing::get(uint64_t frame,float* p,uint32_t ch) const {
    if (!p || ch>32 || frame>=(UINT64_MAX/2-1)) return false;
    const auto& f=frames_[frame%maxRingFrames];
    const auto expected=(frame+1)*2;
    bool ok=f.tag.load(std::memory_order_seq_cst)==expected;
    if (ok) {
        for (uint32_t c=0;c<ch;c++) { auto v=f.data[c].load(std::memory_order_seq_cst); memcpy(p+c,&v,4); }
        ok=f.tag.load(std::memory_order_seq_cst)==expected;
    }
    if (!ok) memset(p,0,ch*sizeof(float));
    return ok;
}
bool MIDIQueue::push(const uint8_t* p,uint32_t n) {
    const auto w=write_.load(std::memory_order_relaxed),r=read_.load(std::memory_order_acquire);
    if (!p || n>4096 || uint32_t(w-r)>4096-n) return false;
    for (uint32_t i=0;i<n;i++) bytes_[(w+i)%4096]=p[i];
    write_.store(w+n,std::memory_order_release); return true;
}
bool MIDIQueue::pop(uint8_t& b) {
    const auto r=read_.load(std::memory_order_relaxed);
    if (r==write_.load(std::memory_order_acquire)) return false;
    b=bytes_[r%4096]; read_.store(r+1,std::memory_order_release); return true;
}
void MIDIQueue::discard() { read_.store(write_.load(std::memory_order_acquire),std::memory_order_release); }
static uint8_t dataLength(uint8_t s) {
    if (s>=0x80 && s<0xf0) return (s>>4)==0xc || (s>>4)==0xd ? 1:2;
    if (s==0xf1 || s==0xf3) return 1;
    if (s==0xf2) return 2;
    return 0;
}
void MIDIParser::reset() { status_=running_=used_=need_=0; sysex_=continued_=false; }
bool MIDIParser::emitSysEx(uint8_t kind,UMP& m) {
    m={}; m.count=2; m.words[0]=0x30000000u | uint32_t(kind)<<20 | uint32_t(used_)<<16;
    for (uint8_t i=0;i<used_;i++) {
        if (i<2) m.words[0]|=uint32_t(data_[i])<<(8*(1-i));
        else m.words[1]|=uint32_t(data_[i])<<(8*(5-i));
    }
    used_=0; return true;
}
bool MIDIParser::feed(uint8_t b,UMP& m) {
    m={};
    if (b>=0xf8) {
        if (b==0xf9 || b==0xfd) return false;
        m.count=1; m.words[0]=0x10000000u | uint32_t(b)<<16; return true;
    }
    if (b==0xf7) {
        if (!sysex_) { status_=running_=used_=need_=0; return false; }
        sysex_=false; return emitSysEx(continued_?3:0,m);
    }
    if (b&0x80) {
        status_=running_=used_=need_=0; sysex_=continued_=false;
        if (b==0xf0) { sysex_=true; return false; }
        if (b==0xf4 || b==0xf5) return false;
        status_=b; if (b<0xf0) running_=b; need_=dataLength(b);
        if (need_) return false;
        if (b==0xf6) { m.count=1; m.words[0]=0x10f60000; return true; }
        return false;
    }
    if (sysex_) {
        // Hold a full six-byte group until another byte arrives, so an exact
        // multiple of six can terminate in a single Complete/End packet.
        if (used_==6) { emitSysEx(continued_?2:1,m); continued_=true; data_[used_++]=b; return true; }
        data_[used_++]=b; return false;
    }
    if (!status_) { status_=running_; need_=dataLength(status_); }
    if (!need_) return false;
    data_[used_++]=b;
    if (used_<need_) return false;
    m.count=1; m.words[0]=(status_<0xf0?0x20000000u:0x10000000u) | uint32_t(status_)<<16 | uint32_t(data_[0])<<8;
    if (need_==2) m.words[0]|=data_[1];
    used_=0; status_=running_; need_=dataLength(status_); return true;
}
Error MIDIEncoder::enqueue(const uint32_t* w,size_t n,MIDIQueue& q) {
    if (!w || n>1024) return Error::capacity;
    uint8_t bytes[4096]; uint32_t used=0; bool sx=sysex_;
    for (size_t i=0;i<n;) {
        const uint32_t a=w[i++]; const auto type=a>>28,group=(a>>24)&15;
        if (group!=0) return Error::unsupported;
        if (type==1 || type==2) {
            const uint8_t s=a>>16, d1=a>>8, d2=a;
            const bool channel=s>=0x80 && s<0xf0;
            if ((type==2)!=channel || (!channel && s!=0xf1 && s!=0xf2 && s!=0xf3 && s!=0xf6 && s!=0xf8 && s!=0xfa && s!=0xfb && s!=0xfc && s!=0xfe && s!=0xff)) return Error::malformed;
            const auto len=dataLength(s);
            if ((len && d1>127) || (len==2 && d2>127) || (sx && s<0xf8)) return Error::malformed;
            if (used+1+len>sizeof(bytes)) return Error::capacity;
            bytes[used++]=s; if (len) bytes[used++]=d1; if (len==2) bytes[used++]=d2;
        } else if (type==3) {
            if (i==n) return Error::truncated;
            const uint32_t b=w[i++]; const auto kind=(a>>20)&15,count=(a>>16)&15;
            if (kind>3 || count>6 || ((kind==0 || kind==1) && sx) || ((kind==2 || kind==3) && !sx)) return Error::malformed;
            if (used+count+2>sizeof(bytes)) return Error::capacity;
            if (kind==0 || kind==1) bytes[used++]=0xf0;
            for (uint32_t j=0;j<count;j++) {
                uint8_t v=j<2 ? a>>(8*(1-j)) : b>>(8*(5-j));
                if (v>127) return Error::malformed; bytes[used++]=v;
            }
            if (kind==0 || kind==3) bytes[used++]=0xf7;
            sx=kind==1 || kind==2;
        } else return Error::unsupported;
    }
    if (!q.push(bytes,used)) return Error::capacity;
    sysex_=sx; return Error::none;
}
bool MIDIPacer::next(MIDIQueue& q,uint8_t& b) {
    if (phase_<rate_) phase_+=3125; // 31,250 baud / 10 bits per DIN byte.
    if (phase_<rate_ || !q.pop(b)) return false;
    phase_-=rate_; return true;
}
bool USBHostClock::reference(uint64_t frame,uint64_t host,double hz) {
    if (!host || !isfinite(hz) || hz<=0) return false;
    if (!host_) {
        firstFrame_=frame_=frame; firstHost_=host_=observedHost_=host;
        ticksPerMicroframe_=hz/8000.0;
        segments_[0]={frame,host,ticksPerMicroframe_}; segmentCount_=1;
        return true;
    }
    if (frame==frame_ && host==observedHost_) return true;
    if (frame<=frame_ || host<=observedHost_) return false;
    const double slope=double(host-firstHost_)/double(frame-firstFrame_);
    if (slope<hz/8000.0*0.98 || slope>hz/8000.0*1.02) return false;
    // Preserve phase continuity at the update. A host-time step of even a few
    // microseconds looks like a large device-frequency jump when successive
    // embedded clock references are only 125 us apart. Slew residual phase
    // error over one second, while tracking the measured long-term frequency.
    const auto predicted=hostTime(frame);
    const double phaseError=double(host)-double(predicted);
    const double adjusted=slope+phaseError/8000.0;
    if (adjusted<hz/8000.0*0.98 || adjusted>hz/8000.0*1.02) return false;
    const uint64_t cutover=frame>mappedThrough_?frame:mappedThrough_;
    const auto cutoverHost=hostTime(cutover);
    ticksPerMicroframe_=adjusted; frame_=frame; host_=cutoverHost; observedHost_=host;
    // Preserve every timestamp already used, including queued future output.
    // ReferenceMicroframe may return a cached controller correlation.
    if (segmentCount_==16) {
        for (unsigned i=1;i<16;i++) segments_[i-1]=segments_[i];
        segmentCount_--;
    }
    segments_[segmentCount_++]={cutover,cutoverHost,ticksPerMicroframe_};
    return true;
}
uint64_t USBHostClock::hostTime(uint64_t frame) const {
    if (!segmentCount_) return 0;
    if (frame>mappedThrough_) mappedThrough_=frame;
    unsigned index=segmentCount_-1;
    while (index && frame<segments_[index].frame) index--;
    const auto& segment=segments_[index];
    const double delta=frame>=segment.frame?double(frame-segment.frame):-double(segment.frame-frame);
    const double host=double(segment.host)+delta*segment.period;
    return host>0?uint64_t(host):0;
}
bool USBClockDecoder::feed(const uint8_t* p,size_t length,uint64_t microframe,USBClockReference& result) {
    if (!p || length<12 || !(p[5]&4)) return false;
    const auto ordinal=p[5]&3;
    if (!ordinal) used_=0;
    if (ordinal!=used_) { used_=0; return false; }
    bytes_[used_++]=p[4];
    if (used_!=4) return false;
    used_=0;
    uint64_t reference=(microframe & ~uint64_t(31)) | (p[5]>>3);
    if (reference>=microframe) { if (reference<32) return false; reference-=32; }
    result={readLE32(bytes_),reference}; return true;
}
void StreamClock::reset() { unwrap_.reset(); observations_=references_=0; }
bool StreamClock::reference(uint32_t raw,uint64_t host,double hz) {
    if (!host || !isfinite(hz) || hz<=0) return false;
    if (!references_) { hostPerTick_=hz/deviceClockHz; }
    else {
        const uint32_t ticks=raw-referenceRaw_;
        if (!ticks && host==referenceHost_) return true;
        if (!ticks || ticks>=0x80000000u || host<=referenceHost_) return false;
        const double slope=double(host-referenceHost_)/ticks;
        if (slope<hz/deviceClockHz*0.98 || slope>hz/deviceClockHz*1.02) return false;
        hostPerTick_+=(slope-hostPerTick_)*0.02;
    }
    referenceRaw_=raw; referenceHost_=host;
    if (references_<2) references_++;
    return true;
}
bool StreamClock::observe(uint32_t raw,uint64_t host,uint64_t sample,double hz) {
    uint64_t tick;
    if (references_) {
        const int32_t delta=static_cast<int32_t>(raw-referenceRaw_);
        const double mapped=double(referenceHost_)+double(delta)*hostPerTick_;
        if (mapped<=0 || delta < -int32_t(deviceClockHz) || delta>int32_t(deviceClockHz)) return false;
        host=uint64_t(mapped);
    }
    if (!host || !isfinite(hz) || hz<=0 || !unwrap_.push(raw,tick)) return false;
    if (!observations_) {
        originTick_=tick; originSample_=sample; firstSample_=sample; firstHost_=host;
        anchorHost_=host; anchorSample_=sample; hostPerSample_=hz/profile_->rate; observations_=1; lastSample_=sample; return true;
    }
    if (sample<=lastSample_ || host<=anchorHost_) return false;
    const uint64_t delta=sample-originSample_;
    const int64_t error=int64_t(tick)-int64_t(originTick_+uint64_t(llround(double(delta)*deviceClockHz/profile_->rate)));
    if (tick<originTick_ || error < -timestampTolerance || error > timestampTolerance) return false;
    const auto elapsed=sample-firstSample_;
    if (elapsed>=profile_->rate/100) {
        const double slope=double(host-firstHost_)/double(elapsed);
        if (slope < hz/profile_->rate*0.98 || slope > hz/profile_->rate*1.02) return false;
        hostPerSample_ += (slope-hostPerSample_)*0.02;
    }
    anchorHost_=host; anchorSample_=sample; lastSample_=sample;
    // Live 828x headers occasionally have a 1,251-tick sample interval. Keep
    // quantization error bounded without tolerating a missing 1,250-tick sample.
    originTick_=tick; originSample_=sample;
    if (observations_<32) observations_++;
    return true;
}
uint32_t StreamClock::timestamp(uint64_t sample) const {
    const double delta=sample>=originSample_?double(sample-originSample_):-double(originSample_-sample);
    return uint32_t(originTick_+int64_t(llround(delta*deviceClockHz/profile_->rate)));
}
uint64_t StreamClock::hostTime(uint64_t sample) const {
    const double delta= sample>=anchorSample_ ? double(sample-anchorSample_) : -double(anchorSample_-sample);
    const double h=double(anchorHost_)+delta*hostPerSample_;
    return h>0 ? uint64_t(h):0;
}
Error planOutputPacket(const StreamClock& clock,uint64_t boundary,uint64_t next,uint32_t& frames) {
    frames=0;
    if (!clock.locked()) return Error::unsupported;
    if (clock.hostTime(next)>=boundary) return Error::none;
    const auto packet=clock.profile().packetSamples;
    if (next>UINT64_MAX-packet || clock.hostTime(next+packet)<boundary) return Error::capacity;
    frames=packet; return Error::none;
}
bool recoverFirstTimestamp(const uint8_t* p,size_t n,uint32_t expected,uint32_t& recovered,const StreamProfile& profile) {
    // Header repair has only been established on the measured 48 kHz profile.
    if(profile.rate!=48000 || !p || n!=8*inputFrameBytes)return false;
    const auto candidate=readBE32(p+inputFrameBytes)-ticksPerSample;
    const auto predictionError=int32_t(candidate-expected);
    const auto firstError=int32_t(readBE32(p)-candidate);
    if(predictionError < -timestampTolerance || predictionError > timestampTolerance ||
       firstError<=-int32_t(ticksPerSample) || firstError>=int32_t(ticksPerSample))return false;
    for(unsigned i=1;i<8;i++) {
        const auto error=int32_t(readBE32(p+i*inputFrameBytes)-(candidate+i*ticksPerSample));
        if(error < -timestampTolerance || error > timestampTolerance)return false;
    }
    recovered=candidate;return true;
}
bool inputPacketTimestampsValid(const uint8_t* p,size_t n,const StreamProfile& profile) {
    if (!p || !n || n>profile.packetSamples*profile.inputBytes || n%profile.inputBytes) return false;
    const uint32_t first=readBE32(p);
    for (size_t i=1;i<n/profile.inputBytes;i++) {
        const auto step=uint32_t(llround(double(i)*deviceClockHz/profile.rate));
        const int32_t error=int32_t(readBE32(p+i*profile.inputBytes)-(first+step));
        if (error < -timestampTolerance || error > timestampTolerance) return false;
    }
    return true;
}
Error unpackFrame(const uint8_t* p,size_t n,float* samples,uint8_t& midi,bool& hasMIDI,const StreamProfile& profile) {
    if (!p || !samples || n!=profile.inputBytes) return Error::malformed;
    for (uint32_t c=0;c<profile.inputs;c++) samples[c]=float(decode24(p+pcmOffset+profile.inputWire(c)*3,true))/8388608.0f;
    hasMIDI=p[midiFlagOffset]&1; midi=p[midiDataOffset]; return Error::none;
}
Error packFrame(uint8_t* p,size_t n,const float* samples,uint32_t timestamp,bool hasMIDI,uint8_t midi,const StreamProfile& profile) {
    if (!p || !samples || n!=profile.outputBytes) return Error::malformed;
    memset(p,0,n); writeBE32(p,timestamp);
    if (hasMIDI) { p[midiFlagOffset]=1; p[midiDataOffset]=midi; }
    // Apps use Main L/R first, then Analog 1-8, Phones, S/PDIF and ADAT.
    // The USB layout puts Phones first and Main at slots 10/11 (zero-based).
    // Translate only here so the HAL buffers and playback ring use app order.
    for (uint32_t c=0;c<profile.outputs;c++) {
        const uint32_t wire=profile.outputWire(c);
        encode24(floatToPCM(samples[c]),p+pcmOffset+wire*3,true);
    }
    return Error::none;
}
}
