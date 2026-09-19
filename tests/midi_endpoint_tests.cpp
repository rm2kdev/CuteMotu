#include "MIDI.hpp"
#include <thread>
#include <chrono>
#include <cstdio>
#include <cstdlib>
using namespace cute;
struct Echo:Backend {MIDI& port;Echo(SharedAudio& a,dispatch_queue_t q,MIDI& p):Backend(a,q),port(p){}bool start(uint32_t)override{return true;}void stop(std::function<void()> f)override{f();}bool setRate(uint32_t)override{return true;}uint32_t subscribe()override{return 0;}uint32_t edit(motu::DSPValue,uint64_t&)override{return 0;}const char* name()const override{return "MIDI test";}void midi(const uint32_t* words,size_t n)override{motu::UMP m{};m.count=uint8_t(n);for(size_t i=0;i<n;i++)m.words[i]=words[i];port.receive(m);}};
#define CHECK(x) do{if(!(x)){fprintf(stderr,"MIDI FAIL line %d: %s\n",__LINE__,#x);abort();}}while(0)
int main(){MIDI port;CHECK(port.open());MIDIClientRef client=0;MIDIPortRef in=0,out=0;CHECK(!MIDIClientCreate(CFSTR("Cute Mix Offline MIDI Test"),nullptr,nullptr,&client));
    std::atomic<unsigned> count{0};uint32_t received[32]{};auto* receivedPtr=received;auto* countPtr=&count;
    CHECK(!MIDIInputPortCreateWithProtocol(client,CFSTR("Test input"),kMIDIProtocol_1_0,&in,^(const MIDIEventList* events,void*){auto p=&events->packet[0];for(unsigned i=0;i<events->numPackets;i++){auto index=countPtr->load();if(index+p->wordCount<=32){for(unsigned j=0;j<p->wordCount;j++)receivedPtr[index+j]=p->words[j];countPtr->store(index+p->wordCount);}p=MIDIEventPacketNext(p);}}));
    CHECK(!MIDIOutputPortCreate(client,CFSTR("Test output"),&out));MIDIEndpointRef source=0,dest=0;
    for(unsigned i=0;i<MIDIGetNumberOfSources();i++){auto e=MIDIGetSource(i);CFStringRef n=nullptr;MIDIObjectGetStringProperty(e,kMIDIPropertyName,&n);if(n && CFEqual(n,CFSTR("Cute Mix USB DIN In")))source=e;if(n)CFRelease(n);}
    for(unsigned i=0;i<MIDIGetNumberOfDestinations();i++){auto e=MIDIGetDestination(i);CFStringRef n=nullptr;MIDIObjectGetStringProperty(e,kMIDIPropertyName,&n);if(n && CFEqual(n,CFSTR("Cute Mix USB DIN Out")))dest=e;if(n)CFRelease(n);}
    CHECK(source && dest);CHECK(!MIDIPortConnectSource(in,source,nullptr));
    uint32_t words[]={0x20903c64,0x20803c00,0x30160102,0x03040506,0x30310700,0};MIDIEventList events{};auto* packet=MIDIEventListInit(&events,kMIDIProtocol_1_0);CHECK(MIDIEventListAdd(&events,sizeof(events),packet,0,6,words));CHECK(!MIDISendEventList(out,dest,&events));
    auto audio=std::make_unique<SharedAudio>();auto q=dispatch_queue_create("midi.test",DISPATCH_QUEUE_SERIAL);Echo echo(*audio,q,port);
    for(unsigned i=0;i<300 && count<6;i++){port.drain(echo);std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    CHECK(count==6);for(unsigned i=0;i<6;i++)CHECK(received[i]==words[i]);MIDIClientDispose(client);port.close();dispatch_release(q);puts("CoreMIDI virtual endpoint roundtrip: note on/off and multipart SysEx passed; physical DIN pending");
}
