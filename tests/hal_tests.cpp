#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include "Client.hpp"
#include "TransportTiming.hpp"
#include <mach/mach_time.h>
#include <chrono>
#include <thread>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <atomic>
using namespace cute;
extern "C" void* CuteMixFactory(CFAllocatorRef,CFUUIDRef);
unsigned checks=0;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#x);std::abort();}checks++;}while(0)
std::atomic<UInt64> change{0};std::atomic<unsigned> notices{0},deviceLists{0},ownedLists{0};
OSStatus changed(AudioServerPlugInHostRef,AudioObjectID id,UInt32 count,const AudioObjectPropertyAddress* addresses){notices++;
    if(id==kAudioObjectPlugInObject){for(UInt32 i=0;i<count;i++){
        if(addresses[i].mSelector==kAudioPlugInPropertyDeviceList)deviceLists++;
        if(addresses[i].mSelector==kAudioObjectPropertyOwnedObjects)ownedLists++;
    }}return 0;}
OSStatus copyStorage(AudioServerPlugInHostRef,CFStringRef,CFPropertyListRef* out){*out=nullptr;return 0;}
OSStatus writeStorage(AudioServerPlugInHostRef,CFStringRef,CFPropertyListRef){return 0;}
OSStatus deleteStorage(AudioServerPlugInHostRef,CFStringRef){return 0;}
OSStatus request(AudioServerPlugInHostRef,AudioObjectID,UInt64 action,void*){change=action;return 0;}
AudioServerPlugInHostInterface host{changed,copyStorage,writeStorage,deleteStorage,request};
AudioObjectPropertyAddress address(UInt32 selector,UInt32 scope=kAudioObjectPropertyScopeGlobal){return {selector,scope,kAudioObjectPropertyElementMain};}
void sleepMs(unsigned n){std::this_thread::sleep_for(std::chrono::milliseconds(n));}
template<class T>T get(AudioServerPlugInDriverRef d,AudioObjectID id,UInt32 selector,UInt32 scope=kAudioObjectPropertyScopeGlobal){T value{};auto a=address(selector,scope);UInt32 n=sizeof(T);CHECK((*d)->GetPropertyData(d,id,0,&a,0,nullptr,sizeof(T),&n,&value)==0);CHECK(n==sizeof(T));return value;}
void registrationProperties(AudioServerPlugInDriverRef d){
    // Core Audio reads visibility during device activation, before publishing it.
    // Compare the public contract with Apple's minimal AudioServerPlugIn sample.
    auto a=address(kAudioDevicePropertyIsHidden);UInt32 bytes=0;Boolean writable=true;
    CHECK((*d)->HasProperty(d,2,0,&a));
    CHECK((*d)->GetPropertyDataSize(d,2,0,&a,0,nullptr,&bytes)==0 && bytes==sizeof(UInt32));
    CHECK((*d)->IsPropertySettable(d,2,0,&a,&writable)==0 && !writable);
    CHECK(get<UInt32>(d,2,kAudioDevicePropertyIsHidden)==0);
    UInt32 hidden=1;CHECK((*d)->SetPropertyData(d,2,0,&a,0,nullptr,sizeof(hidden),&hidden)!=0);
    CHECK(get<UInt32>(d,2,kAudioDevicePropertyIsHidden)==0);
    unsigned char guard[4]={42,42,42,42};bytes=99;
    CHECK((*d)->GetPropertyData(d,2,0,&a,0,nullptr,3,&bytes,guard)==kAudioHardwareBadPropertySizeError);
    CHECK(bytes==0);for(auto value:guard)CHECK(value==42);
    CHECK(!(*d)->HasProperty(d,3,0,&a));
    const AudioObjectPropertySelector scalarProperties[]={kAudioObjectPropertyBaseClass,kAudioObjectPropertyClass,kAudioObjectPropertyOwner,
        kAudioDevicePropertyTransportType,kAudioDevicePropertyClockDomain,kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyDeviceIsRunning,kAudioDevicePropertyZeroTimeStampPeriod};
    for(auto selector:scalarProperties){a=address(selector);CHECK((*d)->HasProperty(d,2,0,&a));bytes=0;
        CHECK((*d)->GetPropertyDataSize(d,2,0,&a,0,nullptr,&bytes)==0 && bytes==sizeof(UInt32));get<UInt32>(d,2,selector);}
    for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}){
        CHECK(get<UInt32>(d,2,kAudioDevicePropertyDeviceCanBeDefaultDevice,scope)==1);
        CHECK(get<UInt32>(d,2,kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,scope)==1);
    }
    // A volume-mode control must not be advertised as a hardware output source:
    // the system Sound menu substitutes source item names for the device name.
    a=address(kAudioDevicePropertyDataSources,kAudioObjectPropertyScopeOutput);
    CHECK(!(*d)->HasProperty(d,2,0,&a));
    a=address(kAudioDevicePropertyDataSource,kAudioObjectPropertyScopeOutput);
    CHECK(!(*d)->HasProperty(d,2,0,&a));
    CHECK(get<UInt32>(d,7,kAudioObjectPropertyClass)==kAudioBooleanControlClassID);
    CHECK(get<UInt32>(d,7,kAudioObjectPropertyBaseClass)==kAudioControlClassID);
    CHECK(get<UInt32>(d,7,kAudioControlPropertyScope)==kAudioObjectPropertyScopeOutput);
    a=address(kAudioBooleanControlPropertyValue);
    for(UInt32 enabled:{1u,0u}){
        CHECK((*d)->SetPropertyData(d,7,0,&a,0,nullptr,sizeof(enabled),&enabled)==0);
        CHECK(get<UInt32>(d,7,kAudioBooleanControlPropertyValue)==enabled);
        CHECK(get<UInt32>(d,6,kAudioBooleanControlPropertyValue)==0);
        auto name=get<CFStringRef>(d,2,kAudioObjectPropertyName);
        CHECK(CFEqual(name,CFSTR("Cute Motu 828x")));CFRelease(name);
    }
    UInt32 invalidMode=2;
    CHECK((*d)->SetPropertyData(d,7,0,&a,0,nullptr,sizeof(invalidMode),&invalidMode)!=0);
    CHECK(get<UInt32>(d,7,kAudioBooleanControlPropertyValue)==0);
    puts("HAL device registration and stable output name properties passed");
}
void published(AudioServerPlugInDriverRef d,bool expected){
    const AudioObjectPropertySelector selectors[]={kAudioPlugInPropertyDeviceList,kAudioObjectPropertyOwnedObjects};
    for(auto selector:selectors){
        auto a=address(selector);UInt32 bytes=99,written=99;AudioObjectID object=99;
        CHECK((*d)->GetPropertyDataSize(d,kAudioObjectPlugInObject,0,&a,0,nullptr,&bytes)==0);CHECK(bytes==(expected?sizeof(AudioObjectID):0));
        CHECK((*d)->GetPropertyData(d,kAudioObjectPlugInObject,0,&a,0,nullptr,sizeof(object),&written,&object)==0);CHECK(written==bytes);CHECK(object==(expected?2:99));
    }
    auto a=address(kAudioPlugInPropertyTranslateUIDToDevice);CFStringRef uid=CFSTR("org.cutemix.usbaudio.prototype");UInt32 bytes=sizeof(AudioObjectID);AudioObjectID object=99;
    CHECK((*d)->GetPropertyData(d,kAudioObjectPlugInObject,0,&a,sizeof(uid),&uid,bytes,&bytes,&object)==0);CHECK(object==(expected?2:kAudioObjectUnknown));
}
int main(int argc,const char** argv){
    setvbuf(stdout,nullptr,_IOLBF,0);
    auto d=static_cast<AudioServerPlugInDriverRef>(CuteMixFactory(nullptr,kAudioServerPlugInTypeUUID));CHECK(d);
    registrationProperties(d);if(argc>1 && !strcmp(argv[1],"--properties-only"))return 0;
    CHECK((*d)->Initialize(d,&host)==0);
    const bool lateStart=argc>1 && !strcmp(argv[1],"--late-start");
    if(lateStart){published(d,false);puts("READY_FOR_CONNECT");fflush(stdout);}
    bool online=false;for(unsigned i=0;i<40;i++){if(get<UInt32>(d,2,kAudioDevicePropertyDeviceIsAlive)){online=true;break;}sleepMs(100);}CHECK(online);
    published(d,true);CHECK(deviceLists>=1 && ownedLists>=1);
    auto uid=get<CFStringRef>(d,2,kAudioDevicePropertyDeviceUID);CHECK(CFEqual(uid,CFSTR("org.cutemix.usbaudio.prototype")));CFRelease(uid);
    AudioObjectPropertyAddress invalid{12345,kAudioObjectPropertyScopeGlobal,0};CHECK(!(*d)->HasProperty(d,2,0,&invalid));invalid=address(kAudioObjectPropertyName);invalid.mElement=100;CHECK(!(*d)->HasProperty(d,2,0,&invalid));
    CHECK((*d)->StartIO(d,2,123)==0);CHECK((*d)->StartIO(d,2,123)==0);CHECK((*d)->StartIO(d,2,124)==0);CHECK((*d)->StopIO(d,2,123)==0);CHECK(get<UInt32>(d,2,kAudioDevicePropertyDeviceIsRunning)==1);CHECK((*d)->StopIO(d,2,124)==0);CHECK(get<UInt32>(d,2,kAudioDevicePropertyDeviceIsRunning)==0);
    for(const auto& p:motu::rateProfiles){
        CHECK((*d)->PerformDeviceConfigurationChange(d,2,p.rate,nullptr)==0);CHECK(get<Float64>(d,2,kAudioDevicePropertyNominalSampleRate)==p.rate);
        const auto outputSafety=get<UInt32>(d,2,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeOutput);
        CHECK(outputSafety>=uint32_t(std::ceil(p.rate*(usbQueueMilliseconds+8)/1000.0)));
        auto in=get<AudioStreamBasicDescription>(d,3,kAudioStreamPropertyVirtualFormat);auto out=get<AudioStreamBasicDescription>(d,4,kAudioStreamPropertyPhysicalFormat);CHECK(in.mChannelsPerFrame==p.inputs && out.mChannelsPerFrame==p.outputs);CHECK(in.mSampleRate==p.rate && out.mSampleRate==p.rate);CHECK(in.mBytesPerFrame==p.inputs*4);
        auto a=address(kAudioStreamPropertyAvailablePhysicalFormats);UInt32 n=0;CHECK((*d)->GetPropertyDataSize(d,4,0,&a,0,nullptr,&n)==0);CHECK(n==6*sizeof(AudioStreamRangedDescription));std::vector<AudioStreamRangedDescription> ranges(6);CHECK((*d)->GetPropertyData(d,4,0,&a,0,nullptr,n,&n,ranges.data())==0);for(unsigned i=0;i<6;i++)CHECK(ranges[i].mFormat.mChannelsPerFrame==motu::rateProfiles[i].outputs);
        // Scalar properties reject undersized buffers without touching them.
        a=address(kAudioDevicePropertyNominalSampleRate);char guard[2]={42,42};n=0;CHECK((*d)->GetPropertyData(d,2,0,&a,0,nullptr,1,&n,guard)!=0);CHECK(guard[0]==42 && guard[1]==42);
        CHECK((*d)->StartIO(d,2,1)==0);Boolean enabled=false,inPlace=false;CHECK((*d)->WillDoIOOperation(d,2,1,kAudioServerPlugInIOOperationWriteMix,&enabled,&inPlace)==0 && enabled && inPlace);
        const auto stampPeriod=get<UInt32>(d,2,kAudioDevicePropertyZeroTimeStampPeriod);CHECK(stampPeriod>=10923);
        Float64 sample;UInt64 time,seed;CHECK((*d)->GetZeroTimeStamp(d,2,1,&sample,&time,&seed)==0);auto last=sample;auto lastHost=time,lastSeed=seed;
        for(unsigned i=0;i<8;i++){sleepMs(2);CHECK((*d)->GetZeroTimeStamp(d,2,1,&sample,&time,&seed)==0);CHECK(sample>=last && uint64_t(sample)%stampPeriod==0);if(sample==last && seed==lastSeed)CHECK(time==lastHost);last=sample;lastHost=time;lastSeed=seed;}
        // Schedule a block ahead of the synthetic device and read it back.
        const auto currentSample=[&]{return sample+(double(mach_absolute_time())-double(time))*p.rate/ticksPerSecond();};
        const double first=std::ceil((currentSample()+p.rate*0.05)/512)*512;AudioServerPlugInIOCycleInfo cycle{};cycle.mOutputTime.mSampleTime=first;cycle.mOutputTime.mFlags=kAudioTimeStampSampleTimeValid;cycle.mInputTime=cycle.mOutputTime;
        std::vector<float> playback(128*p.outputs),recording(128*p.inputs,99);for(unsigned f=0;f<128;f++)for(unsigned c=0;c<p.outputs;c++)playback[f*p.outputs+c]=float(f+c+1)/512;
        CHECK((*d)->DoIOOperation(d,2,4,1,kAudioServerPlugInIOOperationWriteMix,128,&cycle,playback.data(),nullptr)==0);
        for(unsigned wait=0;wait<500;wait++){CHECK((*d)->GetZeroTimeStamp(d,2,1,&sample,&time,&seed)==0);if(currentSample()>=first+512)break;sleepMs(1);}CHECK(currentSample()>=first+512);
        // The timestamp can extrapolate ahead of a delayed synthetic producer.
        // Bound the wait for the actual loopback block, then check every sample.
        for(unsigned wait=0;wait<500;wait++){
            CHECK((*d)->DoIOOperation(d,2,3,1,kAudioServerPlugInIOOperationReadInput,128,&cycle,recording.data(),nullptr)==0);
            if(recording[0]==playback[0] && recording[127*p.inputs]==playback[127*p.outputs])break;
            sleepMs(1);
        }
        for(unsigned f=0;f<128;f++)for(unsigned c=0;c<p.inputs;c++)CHECK(recording[f*p.inputs+c]==(c<p.outputs?playback[f*p.outputs+c]:0));
        cycle.mInputTime.mSampleTime=-1;std::fill(recording.begin(),recording.end(),99);CHECK((*d)->DoIOOperation(d,2,3,1,kAudioServerPlugInIOOperationReadInput,128,&cycle,recording.data(),nullptr)==0);for(float v:recording)CHECK(v==0);
        CHECK((*d)->DoIOOperation(d,2,3,1,kAudioServerPlugInIOOperationReadInput,maxIOFrames+1,&cycle,recording.data(),nullptr)!=0);
        CHECK((*d)->StopIO(d,2,1)==0);printf("HAL formats/timing/loopback/silence: %u Hz passed\n",p.rate);
    }
    auto a=address(kAudioDevicePropertyNominalSampleRate);double unsupported=12345;CHECK((*d)->SetPropertyData(d,2,0,&a,0,nullptr,8,&unsupported)!=0);
    CHECK((*d)->PerformDeviceConfigurationChange(d,2,48000,nullptr)==0);
    if(argc>1 && (!strcmp(argv[1],"--disconnect") || lateStart)){
        CHECK((*d)->StartIO(d,2,1)==0);puts("READY_FOR_DISCONNECT");fflush(stdout);
        bool sawOffline=false;for(unsigned i=0;i<100;i++){if(!get<UInt32>(d,2,kAudioDevicePropertyDeviceIsAlive)){sawOffline=true;break;}sleepMs(100);}CHECK(sawOffline);
        published(d,false);const auto previousLists=deviceLists.load();CHECK(previousLists>=2 && ownedLists>=2);
        AudioServerPlugInIOCycleInfo cycle{};cycle.mInputTime.mSampleTime=0;std::vector<float> samples(32*128,99);CHECK((*d)->DoIOOperation(d,2,3,1,kAudioServerPlugInIOOperationReadInput,128,&cycle,samples.data(),nullptr)==0);for(float v:samples)CHECK(v==0);
        puts("DISCONNECT_SILENCE_PASSED");fflush(stdout);bool recovered=false;for(unsigned i=0;i<150;i++){if(get<UInt32>(d,2,kAudioDevicePropertyDeviceIsAlive)){recovered=true;break;}sleepMs(100);}CHECK(recovered);published(d,true);CHECK(deviceLists>previousLists && ownedLists>=3);puts("RECONNECT_PASSED");CHECK((*d)->StopIO(d,2,1)==0);
    }
    printf("HAL offline host harness: %u checks passed, %u property notifications\n",checks,notices.load());fflush(stdout);_Exit(0);
}
