#include "MOTUPlaybackVolume.hpp"
#include <cassert>
#include <cstdio>
#include <limits>
#include <thread>
static void frame(motu::PlaybackVolume& v,float* f) {for(int c=0;c<30;c++)f[c]=(c%2 ? -.8f:.8f);v.apply(f);for(int c=2;c<30;c++)assert(f[c]==(c%2 ? -.8f:.8f));}
int main() {
    motu::PlaybackVolume v;float f[30];v.beginBuffer();frame(v,f);assert(f[0]==.8f);
    assert(!v.setDecibels(1));assert(!v.setDecibels(-97));assert(!v.setDecibels(std::numeric_limits<float>::quiet_NaN()));assert(!v.setDecibels(std::numeric_limits<float>::infinity()));
    assert(v.setDecibels(-20));v.setEnabled(true);v.beginBuffer();float last=.8f;
    for(unsigned i=0;i<motu::PlaybackVolume::rampFrames;i++){frame(v,f);assert(f[0]<=last && last-f[0]<.004f);assert(f[0]==-f[1]);last=f[0];}
    assert(std::abs(f[0]-.08f)<.00001f);
    v.setMuted(true);v.beginBuffer();for(int i=0;i<240;i++)frame(v,f);assert(f[0]==0 && f[1]==0);
    v.setEnabled(false);v.beginBuffer();for(int i=0;i<240;i++)frame(v,f);assert(f[0]==.8f);
    v.setEnabled(true);v.setMuted(false);v.setDecibels(-96);v.reset();frame(v,f);assert(f[0]==0);
    for(unsigned rate:{44100,48000,88200,96000,176400,192000}) {
        motu::PlaybackVolume ramp;ramp.setSampleRate(rate);ramp.setEnabled(true);ramp.setMuted(true);ramp.beginBuffer();
        for(unsigned i=0;i<rate/200;i++){frame(ramp,f);assert(f[0]>=0 && f[0]<=.8f);if(i+1<rate/200)assert(f[0]>0);}
        assert(f[0]==0);
    }
    // Rapid volume/mute edits never block, boost, or touch another output pair.
    std::thread writer([&]{for(int i=0;i<100000;i++){v.setDecibels(float(-(i%97)));v.setMuted(i%3==0);v.setEnabled(i%5!=0);}});
    for(int i=0;i<100000;i++){v.beginBuffer();frame(v,f);assert(std::isfinite(f[0]) && f[0]>=0 && f[0]<=.801f);}
    writer.join();puts("Playback volume: ramps, mute, bypass, channel isolation, bounds and concurrent edits passed.");
}
