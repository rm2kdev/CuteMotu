#include "Client.hpp"
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <thread>
#include <chrono>
#include <cstdio>
#include <cstdlib>
using namespace cute;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#x);std::abort();}checks++;}while(0)
static unsigned checks=0;
void sleepMs(unsigned n){std::this_thread::sleep_for(std::chrono::milliseconds(n));}
int main(int argc,const char** argv){
    const size_t bytes=(sizeof(SharedAudio)+16383)&~size_t(16383);void* p=mmap(nullptr,bytes,PROT_READ|PROT_WRITE,MAP_SHARED|MAP_ANON,-1,0);CHECK(p!=MAP_FAILED);auto* a=new(p) SharedAudio;
    CHECK(validate(p,bytes));CHECK(!validate(p,bytes-1));a->signature=0;CHECK(!validate(p,bytes));a->signature=magic;a->capacity=1;CHECK(!validate(p,bytes));a->capacity=ringSize;a->rate=12345;CHECK(!validate(p,bytes));a->rate=48000;
    float frame[32],read[32];for(auto& f:frame)f=0.25f;for(auto& f:read)f=1;
    CHECK(!a->input.get(0,1,read,32));for(auto f:read)CHECK(f==0);
    a->input.put(0,1,frame,32);CHECK(a->input.get(0,1,read,32));CHECK(read[0]==0.25f);CHECK(!a->input.get(0,2,read,32));
    a->input.put(ringSize,1,frame,32);CHECK(!a->input.get(0,1,read,32));
    frame[0]=NAN;frame[1]=INFINITY;a->input.put(1,1,frame,32);CHECK(a->input.get(1,1,read,32));CHECK(read[0]==0 && read[1]==0);
    uint64_t index;CHECK(!sampleIndex(-1,1,index));CHECK(!sampleIndex(NAN,1,index));CHECK(!sampleIndex(1.5,1,index));CHECK(!sampleIndex(0,maxIOFrames+1,index));CHECK(sampleIndex(123,512,index) && index==123);
    std::atomic<bool> finished{false};std::atomic<uint64_t> published{0};std::atomic<unsigned> accepted{0},torn{0};
    std::thread producer([&]{float values[32];for(uint64_t i=2;i<200000;i++){for(auto& f:values)f=float(i);a->input.put(i,9,values,32);published=i;if(i%1024==0)std::this_thread::sleep_for(std::chrono::microseconds(20));}finished=true;});
    std::thread consumer([&]{while(!finished){uint64_t i=published.load();float values[32];if(i>=2 && a->input.get(i,9,values,32)){accepted++;for(float f:values)if(f!=float(i))torn++;}}});producer.join();consumer.join();CHECK(!torn);CHECK(finished);CHECK(accepted>100);
    auto memory=xpc_shmem_create(p,bytes);MappingSlot slot;auto map=std::make_unique<Mapping>(memory);CHECK(map->address);slot.replace(std::move(map));
    {MappingSlot::Read r(slot);CHECK(r.audio);slot.replace(nullptr);CHECK(r.audio->signature==magic);}slot.collect();
    std::atomic<bool> mappedDone{false};std::atomic<unsigned> mappedReads{0},badMaps{0};
    std::thread mappingReader([&]{while(!mappedDone){MappingSlot::Read r(slot);if(r.audio){mappedReads++;if(r.audio->signature!=magic)badMaps++;}}});
    for(unsigned i=0;i<200;i++){slot.replace(std::make_unique<Mapping>(memory));std::this_thread::sleep_for(std::chrono::microseconds(50));slot.replace(nullptr);}
    mappedDone=true;mappingReader.join();slot.collect();CHECK(mappedReads>0);CHECK(badMaps==0);
    xpc_release(memory);munmap(p,bytes);
    if(argc==2){Client c;c.connect(argv[1]);auto hello=message("hello");xpc_dictionary_set_string(hello,"role","audio");auto reply=c.request(hello);CHECK(status(reply)==0);
        Mapping mapped(xpc_dictionary_get_value(reply,"memory"));CHECK(mapped.address);auto* audio=mapped.get();xpc_release(reply);
        Client second;second.connect(argv[1]);reply=second.request(hello);CHECK(status(reply)==0xe00002d5);xpc_release(reply);xpc_release(hello);
        hello=message("hello");xpc_dictionary_set_string(hello,"role","control");reply=second.request(hello);CHECK(status(reply)==0);CHECK(!xpc_dictionary_get_value(reply,"memory"));xpc_release(reply);xpc_release(hello);
        auto bad=message("status");xpc_dictionary_set_uint64(bad,"version",999);reply=c.request(bad);CHECK(status(reply)!=0);xpc_release(reply);xpc_release(bad);
        reply=c.call("unknown");CHECK(status(reply)!=0);xpc_release(reply);reply=c.call("edit");CHECK(status(reply)!=0);xpc_release(reply);
        reply=second.call("snapshot");CHECK(!status(reply));size_t metadataBytes=0;auto metadata=xpc_dictionary_get_data(reply,"state",&metadataBytes);CHECK(metadataBytes==9*sizeof(uint64_t));uint64_t state[9];memcpy(state,metadata,sizeof(state));const auto controlEpoch=state[8];xpc_release(reply);
        for(const auto& profile:motu::rateProfiles){auto m=message("rate");xpc_dictionary_set_uint64(m,"rate",profile.rate);reply=c.request(m);CHECK(!status(reply));xpc_release(reply);xpc_release(m);audio->audioActive=1;
            Clock clock;CHECK(audio->snapshot(clock));CHECK(clock.rate==profile.rate);auto period=clockPeriod(clock);auto now=mach_absolute_time();uint64_t first=clock.sample+uint64_t(double(now-clock.host)/period)+uint64_t(profile.rate/20);
            float values[32];for(unsigned f=0;f<128;f++){for(unsigned ch=0;ch<profile.outputs;ch++)values[ch]=float(f+ch+1)/512;audio->output.put(first+f,audio->epoch.load(),values,profile.outputs);}
            for(unsigned wait=0;wait<500 && audio->inputFrames.load()<first+128;wait++)sleepMs(1);CHECK(audio->inputFrames.load()>=first+128);CHECK(audio->fresh(mach_absolute_time(),ticksPerSecond()));
            for(unsigned f=0;f<128;f++){CHECK(audio->input.get(first+f,audio->epoch.load(),values,profile.inputs));for(unsigned ch=0;ch<profile.outputs;ch++)CHECK(values[ch]==float(f+ch+1)/512);for(unsigned ch=profile.outputs;ch<profile.inputs;ch++)CHECK(values[ch]==0);}
            printf("IPC synthetic loopback: %u Hz, %u in / %u out passed\n",profile.rate,profile.inputs,profile.outputs);
        }
        reply=second.call("snapshot");CHECK(!status(reply));metadata=xpc_dictionary_get_data(reply,"state",&metadataBytes);CHECK(metadataBytes==sizeof(state));memcpy(state,metadata,sizeof(state));CHECK(state[8]==controlEpoch);xpc_release(reply);
        auto request=message("rate");xpc_dictionary_set_uint64(request,"rate",48000);reply=c.request(request);CHECK(!status(reply));xpc_release(reply);xpc_release(request);audio->audioActive=0;
    }
    printf("IPC/rings: %u checks passed; concurrent accepted frames=%u, torn=%u\n",checks,accepted.load(),torn.load());return 0;
}
