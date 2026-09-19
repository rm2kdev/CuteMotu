#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <dlfcn.h>
#include <cstdio>

// Inspect the shipped bundle's registration contract without initializing its
// service connection or opening the USB device.
int main(int argc,const char** argv){
    if(argc!=2){std::fprintf(stderr,"Usage: hal-registration-probe HAL-executable\n");return 2;}
    auto bundle=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!bundle){std::fprintf(stderr,"%s\n",dlerror());return 2;}
    auto factory=reinterpret_cast<void*(*)(CFAllocatorRef,CFUUIDRef)>(dlsym(bundle,"CuteMixFactory"));
    if(!factory)return 2;
    auto d=static_cast<AudioServerPlugInDriverRef>(factory(nullptr,kAudioServerPlugInTypeUUID));
    if(!d)return 2;
    AudioObjectPropertyAddress a{kAudioDevicePropertyIsHidden,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    const bool has=(*d)->HasProperty(d,2,0,&a);UInt32 bytes=0,written=0,hidden=99;Boolean writable=true;
    auto sizeStatus=(*d)->GetPropertyDataSize(d,2,0,&a,0,nullptr,&bytes);
    auto getStatus=(*d)->GetPropertyData(d,2,0,&a,0,nullptr,sizeof(hidden),&written,&hidden);
    auto settableStatus=(*d)->IsPropertySettable(d,2,0,&a,&writable);
    std::printf("IsHidden: present=%u sizeStatus=%d bytes=%u getStatus=%d written=%u value=%u settableStatus=%d writable=%u\n",
                unsigned(has),sizeStatus,bytes,getStatus,written,hidden,settableStatus,unsigned(writable));
    return has && !sizeStatus && bytes==4 && !getStatus && written==4 && hidden==0 && !settableStatus && !writable?0:1;
}
