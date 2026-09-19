#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include "Client.hpp"
#include "TransportTiming.hpp"
#include "ZeroTimeStamp.hpp"
#include "MOTUPlaybackVolume.hpp"
#include <algorithm>
#include <cmath>
#include <mutex>
#include <unordered_set>
#include <string>
using namespace cute;
namespace {
// The volume-mode switch is a generic boolean control, never an output source.
// macOS uses source item names as the device label in its Sound menu.
constexpr AudioObjectID device=2,input=3,output=4,volumeID=5,muteID=6,modeID=7;
AudioServerPlugInHostRef host=nullptr;
std::atomic<UInt32> references{1},rate{48000},activeCount{0},mode{0},mute{0};
std::atomic<float> scalar{1};motu::PlaybackVolume volume;
struct PlaybackDiagnostics {
    std::atomic<uint64_t> calls{0},written{0},invalidTime{0},notReady{0},sampleBits{0},usbFrame{0},rejected{0};
    std::atomic<uint32_t> count{0},peakBits{0},afterGainBits{0},streamID{0};
} playback;
MappingSlot mapping;Client client;dispatch_queue_t control=nullptr;dispatch_source_t timer=nullptr;
std::mutex clientsMutex;std::unordered_set<UInt32> activeClients;
std::atomic<uint64_t> seed{1},fallbackOrigin{0};double ticks=0;
ZeroTimeStampCache timeStampCache;
std::string endpoint=serviceName;bool connected=false;uint32_t requestedRate=0;std::atomic<UInt32> alive{0};
extern AudioServerPlugInDriverInterface interface;
AudioServerPlugInDriverInterface* interfacePointer=&interface;
AudioServerPlugInDriverRef driver=&interfacePointer;
OSStatus unknownProperty(AudioObjectID id,const AudioObjectPropertyAddress* a){
    // Core Audio redacts its failing property address. Keep bounded diagnostics
    // on this non-realtime path so an activation failure identifies the query.
    static std::atomic<unsigned> reports{0};
    if(a && reports.fetch_add(1)<32)os_log_error(OS_LOG_DEFAULT,"Cute Mix HAL unknown property: object=%{public}u selector=0x%{public}08x scope=0x%{public}08x element=%{public}u",id,a->mSelector,a->mScope,a->mElement);
    return kAudioHardwareUnknownPropertyError;
}
bool valid(AudioObjectID id){return id>=kAudioObjectPlugInObject && id<=modeID;}
bool stream(AudioObjectID id){return id==input || id==output;}
AudioStreamBasicDescription format(uint32_t hz,bool in){const auto* p=motu::profileForRate(hz);UInt32 channels=in?p->inputs:p->outputs;
    return {double(hz),kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,channels*4,1,channels*4,channels,32,0};}
void changed(AudioObjectID id,AudioObjectPropertySelector selector,AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal){if(host){AudioObjectPropertyAddress a{selector,scope,kAudioObjectPropertyElementMain};host->PropertiesChanged(host,id,1,&a);}}
void publishAvailability(UInt32 online){
    if(alive.exchange(online)==online)return;
    // Core Audio may discard a device that was dead during initial discovery.
    // Publish the parent list as well so a later service connection enumerates it.
    changed(kAudioObjectPlugInObject,kAudioPlugInPropertyDeviceList);
    changed(kAudioObjectPlugInObject,kAudioObjectPropertyOwnedObjects);
    changed(device,kAudioDevicePropertyDeviceIsAlive);
}
void notifyRate(){changed(device,kAudioDevicePropertyNominalSampleRate);for(auto id:{input,output}){changed(id,kAudioStreamPropertyVirtualFormat);changed(id,kAudioStreamPropertyPhysicalFormat);changed(id,kAudioStreamPropertyAvailableVirtualFormats);changed(id,kAudioStreamPropertyAvailablePhysicalFormats);}
    for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}){changed(device,kAudioDevicePropertyLatency,scope);changed(device,kAudioDevicePropertySafetyOffset,scope);changed(device,kAudioDevicePropertyStreamConfiguration,scope);changed(device,kAudioDevicePropertyStreamFormat,scope);}}
void poll(){
    auto reply=client.call("status",300);
    if(status(reply)){if(reply)xpc_release(reply);if(connected){mapping.replace(nullptr);connected=false;seed++;}publishAvailability(0);client.connect(endpoint.c_str());return;}
    if(!connected){auto m=message("hello");xpc_dictionary_set_string(m,"role","audio");auto r=client.request(m,300);xpc_release(m);
        if(!status(r)){auto map=std::make_unique<Mapping>(xpc_dictionary_get_value(r,"memory"));if(map->address){map->get()->audioActive=activeCount.load()?1:0;connected=mapping.replace(std::move(map));seed++;}}
        if(r)xpc_release(r);
    }
    if(connected){MappingSlot::Read read(mapping);auto* a=read.audio;UInt32 online=a && a->fresh(mach_absolute_time(),ticks);publishAvailability(online);
        if(a && a->rate.load()!=rate.load() && a->online.load() && !requestedRate && host){auto next=a->rate.load();if(motu::profileForRate(next)){requestedRate=next;if(host->RequestDeviceConfigurationChange(host,device,next,nullptr))requestedRate=0;}}}
    // Report counters off the real-time thread. No audio samples are logged.
    static unsigned diagnosticPoll=0;
    if(++diagnosticPoll%5==0){
        double sample=0;auto bits=playback.sampleBits.load();memcpy(&sample,&bits,sizeof(sample));
        float peak=0,after=0;auto p=playback.peakBits.load(),q=playback.afterGainBits.load();memcpy(&peak,&p,4);memcpy(&after,&q,4);
        os_log(OS_LOG_DEFAULT,"Cute Mix playback calls=%{public}llu written=%{public}llu badTime=%{public}llu notReady=%{public}llu sample=%{public}.9f usbFrame=%{public}llu count=%{public}u peak=%{public}.6f afterGain=%{public}.6f active=%{public}u rate=%{public}u rejected=%{public}llu stream=%{public}u",
            (unsigned long long)playback.calls.load(),(unsigned long long)playback.written.load(),(unsigned long long)playback.invalidTime.load(),(unsigned long long)playback.notReady.load(),sample,(unsigned long long)playback.usbFrame.load(),playback.count.load(),peak,after,activeCount.load(),rate.load(),(unsigned long long)playback.rejected.load(),playback.streamID.load());
    }
    mapping.collect();xpc_release(reply);
}
HRESULT query(void*,REFIID uuid,LPVOID* out){if(!out)return E_POINTER;*out=nullptr;auto id=CFUUIDCreateFromUUIDBytes(nullptr,uuid);
    bool ok=CFEqual(id,IUnknownUUID) || CFEqual(id,kAudioServerPlugInDriverInterfaceUUID);CFRelease(id);if(!ok)return E_NOINTERFACE;references++;*out=driver;return S_OK;}
ULONG add(void*){return ++references;}ULONG release(void*){auto n=references.load();while(n>1 && !references.compare_exchange_weak(n,n-1)){}return references.load();}
OSStatus initialize(AudioServerPlugInDriverRef,AudioServerPlugInHostRef h){host=h;ticks=ticksPerSecond();fallbackOrigin=mach_absolute_time();volume.setSampleRate(rate.load());
    control=dispatch_queue_create("org.cutemix.usbaudio.hal.control",DISPATCH_QUEUE_SERIAL);
    const char* name=serviceName;
#ifdef CUTE_OFFLINE_HARNESS
    if(auto* env=getenv("CUTE_TEST_MACH_SERVICE"))name=env;
#endif
    endpoint=name;client.connect(name);timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,control);dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,NSEC_PER_SEC,100*NSEC_PER_MSEC);dispatch_source_set_event_handler(timer,^{poll();});dispatch_resume(timer);return 0;
}
OSStatus create(AudioServerPlugInDriverRef,CFDictionaryRef,const AudioServerPlugInClientInfo*,AudioObjectID*){return kAudioHardwareUnsupportedOperationError;}
OSStatus destroy(AudioServerPlugInDriverRef,AudioObjectID){return kAudioHardwareUnsupportedOperationError;}
OSStatus addClient(AudioServerPlugInDriverRef,AudioObjectID id,const AudioServerPlugInClientInfo*){return id==device?0:kAudioHardwareBadObjectError;}
OSStatus stop(AudioServerPlugInDriverRef,AudioObjectID,UInt32);
OSStatus removeClient(AudioServerPlugInDriverRef d,AudioObjectID id,const AudioServerPlugInClientInfo* info){if(!info)return kAudioHardwareIllegalOperationError;return stop(d,id,info->mClientID);}
OSStatus perform(AudioServerPlugInDriverRef,AudioObjectID id,UInt64 action,void*){if(id!=device || action>UINT32_MAX || !motu::profileForRate(uint32_t(action)))return kAudioHardwareIllegalOperationError;
    __block OSStatus result=0;dispatch_sync(control,^{auto m=message("rate");xpc_dictionary_set_uint64(m,"rate",action);auto r=client.request(m);xpc_release(m);
        if(status(r))result=kAudioHardwareNotRunningError;else{rate=uint32_t(action);seed++;fallbackOrigin=mach_absolute_time();volume.setSampleRate(uint32_t(action));}if(r)xpc_release(r);requestedRate=0;});
    if(!result)notifyRate();return result;
}
OSStatus abortChange(AudioServerPlugInDriverRef,AudioObjectID,UInt64,void*){dispatch_async(control,^{requestedRate=0;});return 0;}
Boolean has(AudioServerPlugInDriverRef,AudioObjectID id,pid_t,const AudioObjectPropertyAddress* a){if(!a || !valid(id) || a->mElement!=kAudioObjectPropertyElementMain)return false;
    const auto s=a->mSelector;const auto scope=a->mScope;
    if(scope!=kAudioObjectPropertyScopeGlobal && !(id==device && (scope==kAudioObjectPropertyScopeInput || scope==kAudioObjectPropertyScopeOutput)))return false;
    switch(s){
        case kAudioObjectPropertyBaseClass:case kAudioObjectPropertyClass:case kAudioObjectPropertyOwner:case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioObjectPropertyOwnedObjects:return true;
        default:break;
    }
    if(id==kAudioObjectPlugInObject){switch(s){case kAudioPlugInPropertyBundleID:case kAudioPlugInPropertyDeviceList:case kAudioPlugInPropertyTranslateUIDToDevice:case kAudioPlugInPropertyBoxList:case kAudioPlugInPropertyResourceBundle:return true;default:return false;}}
    if(id==device){switch(s){
        case kAudioDevicePropertyIsHidden:return scope==kAudioObjectPropertyScopeGlobal;
        case kAudioDevicePropertyDeviceUID:case kAudioDevicePropertyModelUID:case kAudioDevicePropertyTransportType:case kAudioDevicePropertyRelatedDevices:case kAudioDevicePropertyClockDomain:case kAudioDevicePropertyDeviceIsAlive:case kAudioDevicePropertyDeviceIsRunning:case kAudioDevicePropertyDeviceCanBeDefaultDevice:case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:case kAudioDevicePropertyLatency:case kAudioDevicePropertySafetyOffset:case kAudioDevicePropertyStreams:case kAudioObjectPropertyControlList:case kAudioDevicePropertyNominalSampleRate:case kAudioDevicePropertyAvailableNominalSampleRates:case kAudioDevicePropertyZeroTimeStampPeriod:case kAudioDevicePropertyStreamConfiguration:case kAudioDevicePropertyStreamFormat:case kAudioDevicePropertyPreferredChannelsForStereo:return true;
        case kAudioDevicePropertyVolumeScalar:case kAudioDevicePropertyVolumeDecibels:case kAudioDevicePropertyVolumeRangeDecibels:case kAudioDevicePropertyMute:return scope==kAudioObjectPropertyScopeOutput;
        default:return false;}}
    if(stream(id)){switch(s){case kAudioStreamPropertyIsActive:case kAudioStreamPropertyDirection:case kAudioStreamPropertyTerminalType:case kAudioStreamPropertyStartingChannel:case kAudioStreamPropertyLatency:case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:return true;default:return false;}}
    if(s==kAudioControlPropertyScope || s==kAudioControlPropertyElement)return true;
    if(id==volumeID){switch(s){case kAudioLevelControlPropertyScalarValue:case kAudioLevelControlPropertyDecibelValue:case kAudioLevelControlPropertyDecibelRange:case kAudioLevelControlPropertyConvertScalarToDecibels:case kAudioLevelControlPropertyConvertDecibelsToScalar:return true;default:return false;}}
    return s==kAudioBooleanControlPropertyValue;
}
OSStatus settable(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,Boolean* value){if(!value || !has(d,id,pid,a))return kAudioHardwareUnknownPropertyError;auto s=a->mSelector;
    *value=s==kAudioDevicePropertyNominalSampleRate || s==kAudioDevicePropertyStreamFormat || s==kAudioStreamPropertyVirtualFormat || s==kAudioStreamPropertyPhysicalFormat || s==kAudioLevelControlPropertyScalarValue || s==kAudioLevelControlPropertyDecibelValue || s==kAudioBooleanControlPropertyValue || s==kAudioDevicePropertyVolumeScalar || s==kAudioDevicePropertyVolumeDecibels || s==kAudioDevicePropertyMute;return 0;}
UInt32 owned(AudioObjectID id,AudioObjectPropertyScope scope,AudioObjectID* list){UInt32 count=0;if(id==kAudioObjectPlugInObject && alive.load())list[count++]=device;
    if(id==device){if(scope!=kAudioObjectPropertyScopeOutput)list[count++]=input;if(scope!=kAudioObjectPropertyScopeInput){list[count++]=output;list[count++]=volumeID;list[count++]=muteID;list[count++]=modeID;}}return count;}
OSStatus dataSize(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32* size){if(!size || !has(d,id,pid,a))return kAudioHardwareUnknownPropertyError;
    switch(a->mSelector){
        case kAudioObjectPropertyName:case kAudioObjectPropertyManufacturer:case kAudioPlugInPropertyBundleID:case kAudioPlugInPropertyResourceBundle:case kAudioDevicePropertyDeviceUID:case kAudioDevicePropertyModelUID:*size=sizeof(CFStringRef);break;
        case kAudioObjectPropertyOwnedObjects:{AudioObjectID list[5];*size=owned(id,a->mScope,list)*4;break;}
        case kAudioPlugInPropertyBoxList:*size=0;break;
        case kAudioPlugInPropertyDeviceList:*size=alive.load()?sizeof(AudioObjectID):0;break;
        case kAudioDevicePropertyStreams:*size=a->mScope==kAudioObjectPropertyScopeGlobal?8:4;break;
        case kAudioObjectPropertyControlList:*size=a->mScope==kAudioObjectPropertyScopeInput?0:12;break;
        case kAudioDevicePropertyNominalSampleRate:*size=sizeof(Float64);break;
        case kAudioDevicePropertyAvailableNominalSampleRates:*size=6*sizeof(AudioValueRange);break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:*size=sizeof(AudioStreamBasicDescription);break;
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:*size=6*sizeof(AudioStreamRangedDescription);break;
        case kAudioDevicePropertyStreamConfiguration:*size=sizeof(AudioBufferList);break;
        case kAudioLevelControlPropertyDecibelRange:case kAudioDevicePropertyVolumeRangeDecibels:*size=sizeof(AudioValueRange);break;
        case kAudioDevicePropertyPreferredChannelsForStereo:*size=8;break;
        default:*size=4;break;
    }return 0;
}
template<class T>OSStatus put(const T& value,UInt32 capacity,UInt32* written,void* out){if(capacity<sizeof(T) || !out)return kAudioHardwareBadPropertySizeError;memcpy(out,&value,sizeof(T));*written=sizeof(T);return 0;}
OSStatus get(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,UInt32 qualifierBytes,const void* qualifier,UInt32 capacity,UInt32* written,void* out){if(!written || !has(d,id,pid,a))return unknownProperty(id,a);*written=0;
    auto s=a->mSelector;UInt32 value=0;CFStringRef text=nullptr;const auto hz=rate.load();const bool in=id==input || (id==device && a->mScope==kAudioObjectPropertyScopeInput);
    switch(s){
        case kAudioObjectPropertyBaseClass:value=id==kAudioObjectPlugInObject || id==device || stream(id)?kAudioObjectClassID:id==volumeID?kAudioLevelControlClassID:id==muteID?kAudioBooleanControlClassID:kAudioControlClassID;break;
        case kAudioObjectPropertyClass:value=id==kAudioObjectPlugInObject?kAudioPlugInClassID:id==device?kAudioDeviceClassID:stream(id)?kAudioStreamClassID:id==volumeID?kAudioVolumeControlClassID:id==muteID?kAudioMuteControlClassID:kAudioBooleanControlClassID;break;
        case kAudioObjectPropertyOwner:value=id==kAudioObjectPlugInObject?kAudioObjectUnknown:id==device?kAudioObjectPlugInObject:device;break;
        case kAudioObjectPropertyName:text=id==device?CFSTR("Cute Motu 828x"):id==input?CFSTR("828x Inputs"):id==output?CFSTR("828x Outputs (Main first)"):id==volumeID?CFSTR("Main L/R playback"):id==muteID?CFSTR("Main L/R mute"):id==modeID?CFSTR("macOS volume control"):CFSTR("Cute Mix USB Audio");break;
        case kAudioObjectPropertyManufacturer:text=CFSTR("Cute Mix");break;
        case kAudioPlugInPropertyBundleID:text=CFSTR("org.cutemix.usbaudio.hal");break;
        case kAudioPlugInPropertyResourceBundle:text=CFSTR("");break;
        case kAudioDevicePropertyDeviceUID:text=CFSTR("org.cutemix.usbaudio.prototype");break;
        case kAudioDevicePropertyModelUID:text=CFSTR("org.cutemix.usbaudio.828x");break;
        case kAudioObjectPropertyOwnedObjects:case kAudioPlugInPropertyDeviceList:case kAudioPlugInPropertyBoxList:case kAudioDevicePropertyRelatedDevices:case kAudioDevicePropertyStreams:case kAudioObjectPropertyControlList:case kAudioDevicePropertyPreferredChannelsForStereo:{
            AudioObjectID list[5]{};UInt32 n=0;if(s==kAudioObjectPropertyOwnedObjects)n=owned(id,a->mScope,list);
            else if(s==kAudioDevicePropertyRelatedDevices || (s==kAudioPlugInPropertyDeviceList && alive.load())){list[n++]=device;}
            else if(s==kAudioDevicePropertyStreams){if(a->mScope!=kAudioObjectPropertyScopeOutput)list[n++]=input;if(a->mScope!=kAudioObjectPropertyScopeInput)list[n++]=output;}
            else if(s==kAudioObjectPropertyControlList && a->mScope!=kAudioObjectPropertyScopeInput){list[n++]=volumeID;list[n++]=muteID;list[n++]=modeID;}
            else if(s==kAudioDevicePropertyPreferredChannelsForStereo){list[n++]=1;list[n++]=2;}
            n=std::min(n,capacity/4);if(n && !out)return kAudioHardwareBadPropertySizeError;if(n)memcpy(out,list,n*4);*written=n*4;return 0;}
        case kAudioPlugInPropertyTranslateUIDToDevice:{if(qualifierBytes!=sizeof(CFStringRef) || !qualifier)return kAudioHardwareBadPropertySizeError;auto uid=*static_cast<const CFStringRef*>(qualifier);value=alive.load() && uid && CFEqual(uid,CFSTR("org.cutemix.usbaudio.prototype"))?device:kAudioObjectUnknown;break;}
        case kAudioDevicePropertyTransportType:value=kAudioDeviceTransportTypeUSB;break;
        case kAudioDevicePropertyClockDomain:value=0;break;
        case kAudioDevicePropertyIsHidden:value=0;break;
        case kAudioDevicePropertyDeviceIsAlive:value=alive.load();break;
        case kAudioDevicePropertyDeviceIsRunning:value=activeCount.load()?1:0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:case kAudioStreamPropertyIsActive:case kAudioStreamPropertyStartingChannel:value=1;break;
        case kAudioDevicePropertyLatency:value=id==device?uint32_t(std::ceil(hz*0.010)):0;break;
        case kAudioDevicePropertySafetyOffset:value=uint32_t(std::ceil(hz*(in?inputSafetySeconds:outputSafetySeconds)));break;
        case kAudioDevicePropertyZeroTimeStampPeriod:value=zeroTimeStampPeriod;break;
        case kAudioDevicePropertyNominalSampleRate:return put(Float64(hz),capacity,written,out);
        case kAudioDevicePropertyAvailableNominalSampleRates:{AudioValueRange list[6];for(unsigned i=0;i<6;i++)list[i]={double(motu::rateProfiles[i].rate),double(motu::rateProfiles[i].rate)};
            auto bytes=std::min(capacity/UInt32(sizeof(list[0])),UInt32(6))*sizeof(list[0]);if(bytes && !out)return kAudioHardwareBadPropertySizeError;if(bytes)memcpy(out,list,bytes);*written=UInt32(bytes);return 0;}
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:return put(format(hz,in),capacity,written,out);
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:{AudioStreamRangedDescription list[6];for(unsigned i=0;i<6;i++){auto r=motu::rateProfiles[i].rate;list[i]={format(r,in),{double(r),double(r)}};}
            auto bytes=std::min(capacity/UInt32(sizeof(list[0])),UInt32(6))*sizeof(list[0]);if(bytes && !out)return kAudioHardwareBadPropertySizeError;if(bytes)memcpy(out,list,bytes);*written=UInt32(bytes);return 0;}
        case kAudioDevicePropertyStreamConfiguration:{AudioBufferList list{1,{{format(hz,in).mChannelsPerFrame,0,nullptr}}};return put(list,capacity,written,out);}
        case kAudioStreamPropertyDirection:value=in?1:0;break;
        case kAudioStreamPropertyTerminalType:value=in?kAudioStreamTerminalTypeLine:kAudioStreamTerminalTypeSpeaker;break;
        case kAudioControlPropertyScope:value=kAudioObjectPropertyScopeOutput;break;
        case kAudioControlPropertyElement:value=kAudioObjectPropertyElementMain;break;
        case kAudioLevelControlPropertyScalarValue:case kAudioDevicePropertyVolumeScalar:return put(scalar.load(),capacity,written,out);
        case kAudioLevelControlPropertyDecibelValue:case kAudioDevicePropertyVolumeDecibels:return put(scalar.load()>0?std::max(-96.0f,20*std::log10(scalar.load())):-96.0f,capacity,written,out);
        case kAudioLevelControlPropertyDecibelRange:case kAudioDevicePropertyVolumeRangeDecibels:return put(AudioValueRange{-96,0},capacity,written,out);
        case kAudioLevelControlPropertyConvertScalarToDecibels:case kAudioLevelControlPropertyConvertDecibelsToScalar:{if(capacity<4 || !out)return kAudioHardwareBadPropertySizeError;float v;memcpy(&v,out,4);if(!std::isfinite(v))return kAudioHardwareIllegalOperationError;v=s==kAudioLevelControlPropertyConvertScalarToDecibels?(v<=0?-96:std::clamp(20*std::log10(v),-96.0f,0.0f)):(v<=-96?0:std::pow(10.0f,std::clamp(v,-96.0f,0.0f)/20));return put(v,capacity,written,out);}
        case kAudioBooleanControlPropertyValue:value=id==modeID?mode.load():mute.load();break;
        case kAudioDevicePropertyMute:value=mute.load();break;
        default:return kAudioHardwareUnknownPropertyError;
    }
    if(text){CFRetain(text);auto result=put(text,capacity,written,out);if(result)CFRelease(text);return result;}return put(value,capacity,written,out);
}
OSStatus set(AudioServerPlugInDriverRef d,AudioObjectID id,pid_t pid,const AudioObjectPropertyAddress* a,UInt32,const void*,UInt32 size,const void* data){Boolean ok=false;if(settable(d,id,pid,a,&ok) || !ok || !data)return kAudioHardwareUnknownPropertyError;auto s=a->mSelector;
    if(s==kAudioDevicePropertyNominalSampleRate || s==kAudioDevicePropertyStreamFormat || s==kAudioStreamPropertyVirtualFormat || s==kAudioStreamPropertyPhysicalFormat){double desired=0;
        if(s==kAudioDevicePropertyNominalSampleRate){if(size!=8)return kAudioHardwareBadPropertySizeError;memcpy(&desired,data,8);}
        else {if(size!=sizeof(AudioStreamBasicDescription))return kAudioHardwareBadPropertySizeError;AudioStreamBasicDescription supplied;memcpy(&supplied,data,size);desired=supplied.mSampleRate;
            if(!std::isfinite(desired) || desired<1 || desired>192000 || !motu::profileForRate(uint32_t(desired)))return kAudioDeviceUnsupportedFormatError;
            const auto expected=format(uint32_t(desired),id==input || (id==device && a->mScope==kAudioObjectPropertyScopeInput));if(memcmp(&expected,&supplied,sizeof(expected)))return kAudioDeviceUnsupportedFormatError;}
        if(!std::isfinite(desired) || desired<1 || desired>192000 || double(uint32_t(desired))!=desired || !motu::profileForRate(uint32_t(desired)))return kAudioDeviceUnsupportedFormatError;
        if(uint32_t(desired)==rate.load())return 0;if(!host)return kAudioHardwareNotRunningError;
        dispatch_async(control,^{if(!requestedRate){requestedRate=uint32_t(desired);if(host->RequestDeviceConfigurationChange(host,device,uint32_t(desired),nullptr))requestedRate=0;}});return 0;
    }
    if(size!=4)return kAudioHardwareBadPropertySizeError;
    if(s==kAudioLevelControlPropertyScalarValue || s==kAudioLevelControlPropertyDecibelValue || s==kAudioDevicePropertyVolumeScalar || s==kAudioDevicePropertyVolumeDecibels){float v;memcpy(&v,data,4);const bool db=s==kAudioLevelControlPropertyDecibelValue || s==kAudioDevicePropertyVolumeDecibels;
        if(!std::isfinite(v) || (db?(v< -96 || v>0):(v<0 || v>1)))return kAudioHardwareIllegalOperationError;scalar=db?(v<=-96?0:std::pow(10.0f,v/20)):v;volume.setDecibels(scalar.load()>0?20*std::log10(scalar.load()):-96);
        changed(volumeID,kAudioLevelControlPropertyScalarValue);changed(volumeID,kAudioLevelControlPropertyDecibelValue);changed(device,kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeOutput);changed(device,kAudioDevicePropertyVolumeDecibels,kAudioObjectPropertyScopeOutput);
    }else{UInt32 v;memcpy(&v,data,4);if(v>1)return kAudioHardwareIllegalOperationError;
        if(id!=modeID){mute=v;volume.setMuted(v);changed(muteID,kAudioBooleanControlPropertyValue);changed(device,kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput);}
        else{mode=v;volume.setEnabled(v);changed(modeID,kAudioBooleanControlPropertyValue);}}
    return 0;
}
OSStatus start(AudioServerPlugInDriverRef,AudioObjectID id,UInt32 clientID){if(id!=device)return kAudioHardwareBadObjectError;std::lock_guard<std::mutex> lock(clientsMutex);activeClients.insert(clientID);activeCount=UInt32(activeClients.size());MappingSlot::Read r(mapping);if(r.audio)r.audio->audioActive=1;changed(device,kAudioDevicePropertyDeviceIsRunning);return 0;}
OSStatus stop(AudioServerPlugInDriverRef,AudioObjectID id,UInt32 clientID){if(id!=device)return kAudioHardwareBadObjectError;std::lock_guard<std::mutex> lock(clientsMutex);activeClients.erase(clientID);activeCount=UInt32(activeClients.size());MappingSlot::Read r(mapping);if(r.audio){r.audio->audioActive=activeCount.load()?1:0;if(!activeCount.load())r.audio->epoch.fetch_add(1);}changed(device,kAudioDevicePropertyDeviceIsRunning);return 0;}
OSStatus timestamp(AudioServerPlugInDriverRef,AudioObjectID id,UInt32,Float64* sample,UInt64* time,UInt64* timestampSeed){if(id!=device || !sample || !time || !timestampSeed)return kAudioHardwareIllegalOperationError;
    auto now=mach_absolute_time();double period=ticks/rate.load();uint64_t anchor=fallbackOrigin.load(),index=0,epoch=0;MappingSlot::Read r(mapping);Clock c;
    if(r.audio && r.audio->fresh(now,ticks) && r.audio->snapshot(c) && c.rate==rate.load()){auto p=clockPeriod(c);if(std::isfinite(p) && p>period*0.98 && p<period*1.02){period=p;anchor=c.host;index=c.sample;epoch=c.epoch;}}
    double current=double(index)+(now>=anchor?double(now-anchor)/period:-double(anchor-now)/period);auto boundary=uint64_t(std::max(0.0,std::floor(current/zeroTimeStampPeriod)*zeroTimeStampPeriod));
    const double mapped=double(anchor)+(double(boundary)-double(index))*period;
    ZeroTimeStamp stamp;
    if(!timeStampCache.get({boundary,uint64_t(std::max(0.0,mapped)),(seed.load()<<32)|epoch},stamp))return kAudioHardwareNotRunningError;
    *sample=double(stamp.sample);*time=stamp.host;*timestampSeed=stamp.seed;return 0;
}
OSStatus will(AudioServerPlugInDriverRef,AudioObjectID id,UInt32,UInt32 operation,Boolean* enabled,Boolean* inPlace){if(id!=device || !enabled || !inPlace)return kAudioHardwareIllegalOperationError;*enabled=operation==kAudioServerPlugInIOOperationReadInput || operation==kAudioServerPlugInIOOperationWriteMix;*inPlace=true;return 0;}
OSStatus begin(AudioServerPlugInDriverRef,AudioObjectID id,UInt32,UInt32,UInt32,const AudioServerPlugInIOCycleInfo*){return id==device?0:kAudioHardwareBadObjectError;}
OSStatus io(AudioServerPlugInDriverRef,AudioObjectID id,AudioObjectID streamID,UInt32,UInt32 operation,UInt32 count,const AudioServerPlugInIOCycleInfo* cycle,void* buffer,void*){
    if(operation==kAudioServerPlugInIOOperationWriteMix){playback.calls.fetch_add(1);playback.count=count;playback.streamID=streamID;if(cycle){uint64_t bits=0;memcpy(&bits,&cycle->mOutputTime.mSampleTime,8);playback.sampleBits=bits;}}
    if(id!=device || !cycle || !buffer || count>maxIOFrames){playback.rejected.fetch_add(1);return kAudioHardwareIllegalOperationError;}
    const bool read=operation==kAudioServerPlugInIOOperationReadInput;if((read && streamID!=input) || (!read && (operation!=kAudioServerPlugInIOOperationWriteMix || streamID!=output))){playback.rejected.fetch_add(1);return kAudioHardwareUnsupportedOperationError;}
    const auto* p=motu::profileForRate(rate.load());const auto channels=read?p->inputs:p->outputs;auto* pcm=static_cast<float*>(buffer);
    uint64_t frame=0;const bool validTime=sampleIndex(read?cycle->mInputTime.mSampleTime:cycle->mOutputTime.mSampleTime,count,frame);
    MappingSlot::Read r(mapping);auto* a=r.audio;const bool ready=validTime && activeCount.load() && a && a->rate.load()==p->rate && a->fresh(mach_absolute_time(),ticks);const auto epoch=a?a->epoch.load():0;
    if(!read){playback.usbFrame=a?a->outputFrames.load():0;if(!validTime)playback.invalidTime.fetch_add(1);else if(!ready)playback.notReady.fetch_add(1);}
    if(read){if(!ready)memset(pcm,0,count*channels*4);else for(unsigned f=0;f<count;f++)a->input.get(frame+f,epoch,pcm+f*channels,channels);}
    else if(ready){volume.beginBuffer();float peak=0,after=0;for(unsigned f=0;f<count;f++){float values[maxChannels]{};memcpy(values,pcm+f*channels,channels*4);peak=std::max(peak,std::max(std::abs(values[0]),std::abs(values[1])));volume.apply(values);after=std::max(after,std::max(std::abs(values[0]),std::abs(values[1])));a->output.put(frame+f,epoch,values,channels);}uint32_t pbits=0,abits=0;memcpy(&pbits,&peak,4);memcpy(&abits,&after,4);playback.peakBits=pbits;playback.afterGainBits=abits;playback.written.fetch_add(count);}
    return 0;
}
AudioServerPlugInDriverInterface interface={nullptr,query,add,release,initialize,create,destroy,addClient,removeClient,perform,abortChange,has,settable,dataSize,get,set,start,stop,timestamp,will,begin,io,begin};
}
extern "C" __attribute__((visibility("default"))) void* CuteMixFactory(CFAllocatorRef,CFUUIDRef type){return CFEqual(type,kAudioServerPlugInTypeUUID)?driver:nullptr;}
