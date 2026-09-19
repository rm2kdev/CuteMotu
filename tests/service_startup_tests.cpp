#include "Client.hpp"
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <thread>
#include <chrono>
#include <cstdio>
#include <cstdlib>
using namespace cute;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Service startup FAIL line %d: %s\n",__LINE__,#x);std::abort();}}while(0)
int main(int argc,const char** argv){
    CHECK(argc==2);Client c;c.connect(argv[1]);auto reply=c.call("status");
    CHECK(!status(reply));CHECK(xpc_dictionary_get_bool(reply,"online"));
    CHECK(xpc_dictionary_get_value(reply,"midiAvailable"));CHECK(!xpc_dictionary_get_bool(reply,"midiAvailable"));
    CHECK(xpc_dictionary_get_int64(reply,"midiStatus")==kMIDIServerStartErr);xpc_release(reply);
    auto hello=message("hello");xpc_dictionary_set_string(hello,"role","audio");reply=c.request(hello);xpc_release(hello);
    CHECK(!status(reply));Mapping mapping(xpc_dictionary_get_value(reply,"memory"));CHECK(mapping.address);xpc_release(reply);
    auto* audio=mapping.get();const auto before=audio->inputFrames.load();
    for(unsigned i=0;i<200 && audio->inputFrames.load()<=before;i++)std::this_thread::sleep_for(std::chrono::milliseconds(1));
    CHECK(audio->inputFrames.load()>before);CHECK(audio->fresh(mach_absolute_time(),ticksPerSecond()));
    puts("MIDI-unavailable startup: service stays online, reports MIDI error, serves shared audio and advances input.");
}
