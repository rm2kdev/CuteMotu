#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include "MOTUProtocol.hpp"
#include "MOTUStream.hpp"
#include <algorithm>
#include <cstring>
#include <memory>
#include <vector>
#include <thread>
#include <cmath>

static NSString* hex(const void* bytes,size_t n) {
    auto p=static_cast<const uint8_t*>(bytes);NSMutableString* s=[NSMutableString stringWithCapacity:n*2];
    for(size_t i=0;i<n;i++)[s appendFormat:@"%02x",p[i]];return s;
}
static bool waitDone(dispatch_semaphore_t sem,IOUSBHostPipe* pipe) {
    if(!dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)))return true;
    [pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))) {
        fprintf(stderr,"USB callback did not drain; terminating diagnostic process.\n");_Exit(3);
    }
    return false;
}
static bool command(IOUSBHostPipe* in,IOUSBHostPipe* out,uint8_t seq,uint32_t address,bool write,uint32_t value,NSMutableArray* reports) {
    auto c=write?motu::writeRegister(seq,address,value):motu::readRegister(seq,address);
    NSMutableData* request=[NSMutableData dataWithBytes:c.bytes length:c.length];
    NSMutableData* reply=[NSMutableData dataWithLength:256];
    auto rd=dispatch_semaphore_create(0),wr=dispatch_semaphore_create(0);
    __block IOReturn rs=kIOReturnInvalid,ws=kIOReturnInvalid;__block NSUInteger rn=0,wn=0;
    NSError* error=nil;
    if(![in enqueueIORequestWithData:reply completionTimeout:0 error:&error completionHandler:^(IOReturn s,NSUInteger n){rs=s;rn=n;dispatch_semaphore_signal(rd);}]){
        [reports addObject:@{@"error":error.description?:@"read submission"}];return false;
    }
    if(![out enqueueIORequestWithData:request completionTimeout:0 error:&error completionHandler:^(IOReturn s,NSUInteger n){ws=s;wn=n;dispatch_semaphore_signal(wr);}]){
        [in abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];waitDone(rd,in);
        [reports addObject:@{@"error":error.description?:@"write submission"}];return false;
    }
    bool wrote=waitDone(wr,out),read=waitDone(rd,in);
    motu::Reply parsed{};motu::RegisterReplyScanner scanner;scanner.begin(seq,address,write);
    bool matched=false;const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(1);
    while(wrote&&read&&!rs&&!ws&&rn<=256) {
        if(scanner.feed(static_cast<const uint8_t*>(reply.bytes),rn,parsed)){matched=true;break;}
        if(std::chrono::steady_clock::now()>=deadline)break;
        if(![in enqueueIORequestWithData:reply completionTimeout:0 error:&error completionHandler:^(IOReturn s,NSUInteger n){rs=s;rn=n;dispatch_semaphore_signal(rd);}])break;
        read=waitDone(rd,in);
    }
    bool passed=wrote&&read&&!rs&&!ws&&wn==c.length&&matched&&!parsed.status;
    [reports addObject:@{@"sequence":@(seq),@"address":@(address),@"write":@(write),@"passed":@(passed),
      @"readStatus":@(uint32_t(rs)),@"writeStatus":@(uint32_t(ws)),@"reply":hex(reply.bytes,std::min<NSUInteger>(rn,256)),@"value":@(parsed.value)}];
    return passed;
}
// Input-only protocol capture. Requires the experimental stream to be fully
// drained, and obtains exclusive interface access before writing any register.
int main(int argc,const char** argv){@autoreleasepool{
    if((argc!=3 && argc!=4) || strcmp(argv[1],"--capture-rate-input") || (argc==4 && strcmp(argv[3],"--start-playback-engine") && strcmp(argv[3],"--prime-silence"))){fprintf(stderr,"Usage: rate-capture --capture-rate-input Hz [--start-playback-engine|--prime-silence]\n");return 2;}
    const bool primeSilence=argc==4&&!strcmp(argv[3],"--prime-silence");
    const bool startPlayback=argc==4&&!primeSilence;
    char* end=nullptr;auto rate=strtoul(argv[2],&end,10);
    const auto* profile=motu::profileForRate(uint32_t(rate));if(!end||*end||!profile)return 2;
    io_iterator_t drivers=0;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("MOTU828xDriver"),&drivers);
    bool busy=false;io_service_t service;
    while((service=IOIteratorNext(drivers))){
        CFTypeRef value=IORegistryEntryCreateCFProperty(service,CFSTR("MOTUShutdown"),kCFAllocatorDefault,0);
        if(!value || !CFEqual(value,CFSTR("drained")))busy=true;
        if(value)CFRelease(value);IOObjectRelease(service);
    }
    IOObjectRelease(drivers);
    if(busy){fprintf(stderr,"Refusing capture: driver has not drained.\n");return 1;}
    auto match=[IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x07fd productID:@2 bcdDevice:nil interfaceNumber:@0 configurationValue:@1 interfaceClass:@255 interfaceSubclass:@4 interfaceProtocol:@255 speed:nil productIDArray:nil];
    service=IOServiceGetMatchingService(kIOMainPortDefault,match);if(!service){fprintf(stderr,"828x interface absent.\n");return 1;}
    NSError* error=nil;
    IOUSBHostInterface* interface=[[IOUSBHostInterface alloc]initWithIOService:service options:IOUSBHostObjectInitOptionsNone queue:nil error:&error interestHandler:nil];IOObjectRelease(service);
    if(!interface){fprintf(stderr,"Exclusive interface open failed: %s\n",error.description.UTF8String);return 1;}
    const auto* descriptor=interface.configurationDescriptor;motu::Configuration configuration;
    if(!descriptor || motu::parseConfiguration(reinterpret_cast<const uint8_t*>(descriptor),OSSwapLittleToHostInt16(descriptor->wTotalLength),configuration)!=motu::Error::none || motu::validate828x(configuration)!=motu::Error::none){[interface destroy];return 1;}
    IOUSBHostPipe* in=[interface copyPipeWithAddress:0x82 error:&error];
    IOUSBHostPipe* out=[interface copyPipeWithAddress:1 error:&error];
    NSMutableArray* commands=[NSMutableArray array];uint8_t sequence=120;
    bool ok=in&&out;
    if(ok){ok=command(in,out,sequence++,motu::firmwareRegister,false,0,commands);if(!ok)ok=command(in,out,sequence++,motu::firmwareRegister,false,0,commands);}
    if(ok)ok=command(in,out,sequence++,motu::clockRegister,false,0,commands);
    const uint32_t originalClock=[commands.lastObject[@"value"] unsignedIntValue];
    const auto* originalProfile=ok?motu::profileForClock(originalClock):nullptr;
    if(ok)ok=command(in,out,sequence++,motu::opticalRegister,false,0,commands);
    ok=ok&&originalProfile&&motu::supportedClock(originalClock,[commands.lastObject[@"value"] unsignedIntValue]);
    if(!ok){[interface destroy];NSDictionary* report=@{@"passed":@NO,@"commands":commands,@"error":@"Initial configuration validation failed"};NSData* json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');return 1;}
    ok=command(in,out,sequence++,motu::streamRegister,true,0x80800000,commands);
    const auto clockWord=motu::rateClockWord(originalClock,*profile);
    if(ok)ok=command(in,out,sequence++,motu::clockRegister,true,clockWord,commands);
    std::this_thread::sleep_for(std::chrono::milliseconds(2500));
    if(ok)ok=[interface selectAlternateSetting:profile->alternate error:&error];
    in=[interface copyPipeWithAddress:0x82 error:&error];out=[interface copyPipeWithAddress:1 error:&error];
    IOUSBHostPipe* audio=[interface copyPipeWithAddress:0x84 error:&error];ok=ok&&in&&out&&audio;
    constexpr unsigned slots=4,count=128;
    struct Capture {NSMutableData* data=nil;std::vector<IOUSBHostIsochronousTransaction> frames;dispatch_semaphore_t done;IOReturn status=kIOReturnInvalid;bool submitted=false;uint64_t first=0;};
    auto captures=std::make_shared<std::vector<Capture>>(slots);
    auto output=std::make_shared<std::vector<Capture>>(slots);
    IOUSBHostPipe* audioOut=primeSilence?[interface copyPipeWithAddress:3 error:&error]:nil;
    motu::StreamClock streamClock;streamClock.configure(*profile);
    motu::USBClockDecoder clockDecoder;
    uint64_t rxFrame=0,txFrame=0,nextOutput=0;bool primed=false;uint64_t clockErrors=0,outputCompletions=0;
    const auto queueOutput=[&](unsigned i){
        auto& c=(*output)[i];if(!c.data)c.data=[NSMutableData dataWithLength:count*profile->outputCapacity];
        c.frames.resize(count);c.done=dispatch_semaphore_create(0);c.first=nextOutput;nextOutput+=count/8;
        auto* bytes=static_cast<uint8_t*>(c.data.mutableBytes);uint32_t offset=0;
        for(unsigned m=0;m<count;m++) {
            c.frames[m]={};c.frames[m].offset=offset;uint32_t samples=0;
            const auto boundary=(c.first*8+m+1)*7500+30000;
            if(motu::planOutputPacket(streamClock,boundary,txFrame,samples)!=motu::Error::none){ok=false;return;}
            for(unsigned sample=0;sample<samples;sample++){
                float silence[motu::outputChannels]{};
                if(motu::packFrame(bytes+offset,profile->outputBytes,silence,streamClock.timestamp(txFrame++),false,0,*profile)!=motu::Error::none){ok=false;return;}
                offset+=profile->outputBytes;
            }
            c.frames[m].requestCount=samples*profile->outputBytes;
        }
        c.submitted=[audioOut enqueueIORequestWithData:c.data transactionList:c.frames.data() transactionListCount:count firstFrameNumber:c.first options:IOUSBHostIsochronousTransferOptionsNone error:&error completionHandler:^(IOReturn status,IOUSBHostIsochronousTransaction*){auto& done=(*output)[i];done.status=status;dispatch_semaphore_signal(done.done);}];
        ok=ok&&c.submitted;
    };
    IOUSBHostTime host=0;uint64_t next=[interface frameNumberWithTime:&host]+8;
    const auto queueSlot=[&](unsigned i){
        auto& c=(*captures)[i];void* storage=nullptr;const auto capacity=count*profile->inputCapacity;
        if(!c.data){if(posix_memalign(&storage,16384,capacity)){ok=false;return;}
            c.data=[NSMutableData dataWithBytesNoCopy:storage length:capacity freeWhenDone:YES];}
        memset(c.data.mutableBytes,0,capacity);c.frames.resize(count);c.done=dispatch_semaphore_create(0);
        for(unsigned m=0;m<count;m++){c.frames[m]={};c.frames[m].requestCount=profile->inputCapacity;c.frames[m].offset=m*profile->inputCapacity;}
        c.first=next;next+=count/8;
        c.submitted=[audio enqueueIORequestWithData:c.data transactionList:c.frames.data() transactionListCount:count firstFrameNumber:c.first options:IOUSBHostIsochronousTransferOptionsNone error:&error completionHandler:^(IOReturn status,IOUSBHostIsochronousTransaction*){auto& done=(*captures)[i];done.status=status;dispatch_semaphore_signal(done.done);}];
        ok=ok&&c.submitted;
    };
    for(unsigned i=0;ok&&i<slots;i++)queueSlot(i);
    if(ok){ok=command(in,out,sequence++,motu::streamRegister,true,0x00c00000,commands);if(!ok)ok=command(in,out,sequence++,motu::streamRegister,true,0x00c00000,commands);}
    if(ok&&startPlayback)ok=command(in,out,sequence++,motu::streamRegister,true,0xc0c00000,commands);
    if(ok&&startPlayback)ok=command(in,out,sequence++,motu::clockRegister,true,clockWord|0x02000000u,commands);
    struct Snapshot {NSData* data;std::vector<IOUSBHostIsochronousTransaction> frames;uint64_t first;unsigned round;unsigned slot;};
    std::vector<Snapshot> snapshots;snapshots.reserve(256);
    NSMutableArray* packets=[NSMutableArray array];
    for(unsigned round=0;round<64;round++)for(unsigned i=0;i<slots;i++){
        auto& c=(*captures)[i];if(!c.submitted)continue;
        bool drained=waitDone(c.done,audio);c.submitted=false;ok=ok&&drained;
        if(!drained)continue;
        snapshots.push_back({[c.data copy],c.frames,c.first,round,i});
        if(primeSilence&&ok)for(unsigned m=0;m<count;m++) {
            const auto& f=c.frames[m];if(!f.completeCount)continue;
            auto* bytes=static_cast<const uint8_t*>(c.data.bytes)+f.offset;
            if((f.status && !(f.status==kIOReturnUnderrun && f.completeCount==profile->inputPacketBytes())) || f.completeCount>profile->inputCapacity || !motu::inputPacketTimestampsValid(bytes,f.completeCount,*profile)) {clockErrors++;ok=false;break;}
            clockDecoder.beginPacket();
            for(unsigned b=0;b+profile->inputBytes<=f.completeCount;b+=profile->inputBytes){
                motu::USBClockReference reference;
                if(clockDecoder.feed(bytes+b,profile->inputBytes,c.first*8+m,reference))
                    if(!streamClock.reference(reference.tick,reference.microframe*7500,60000000.0)){clockErrors++;ok=false;break;}
            }
            if(!ok)break;
            if(streamClock.hasReference() && !streamClock.observe(motu::readBE32(bytes),(c.first*8+m)*7500,rxFrame,60000000.0)){clockErrors++;ok=false;break;}
            rxFrame+=f.completeCount/profile->inputBytes;
        }
        if(primeSilence&&ok&&!primed&&round>=2&&streamClock.locked()) {
            nextOutput=[interface frameNumberWithTime:&host]+8;
            const auto target=nextOutput*8*7500;
            const auto receive=streamClock.hostTime(rxFrame);
            if(target<receive)ok=false;
            else {
                txFrame=rxFrame+uint64_t(std::ceil(double(target-receive)*profile->rate/60000000.0))+uint64_t(std::ceil(profile->rate*0.0005));
                for(unsigned o=0;o<slots&&ok;o++)queueOutput(o);
                if(ok)ok=command(in,out,sequence++,motu::streamRegister,true,0xc0c00000,commands);
                if(ok)ok=command(in,out,sequence++,motu::clockRegister,true,clockWord|0x02000000u,commands);
                primed=ok;
            }
        }
        if(primed)for(unsigned o=0;o<slots;o++) {
            auto& outSlot=(*output)[o];if(!outSlot.submitted || dispatch_semaphore_wait(outSlot.done,DISPATCH_TIME_NOW))continue;
            outSlot.submitted=false;outputCompletions++;
            for(const auto& f:outSlot.frames)if(f.status || f.completeCount!=f.requestCount)ok=false;
            if(outSlot.status)ok=false;
            if(ok&&round<63)queueOutput(o);
        }
        if(ok&&round<63)queueSlot(i);
    }
    if(primeSilence && (!primed || !outputCompletions))ok=false;
    if(audioOut) {
        [audioOut abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        for(auto& c:*output)if(c.submitted){waitDone(c.done,audioOut);c.submitted=false;}
    }
    bool stopped=in&&out&&command(in,out,sequence++,motu::streamRegister,true,0x80800000,commands);
    bool restored=in&&out&&command(in,out,sequence++,motu::clockRegister,true,originalClock&~0x02000000u,commands);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    restored=[interface selectAlternateSetting:originalProfile->alternate error:&error]&&restored;
    [interface destroy];
    uint64_t validPackets=0,invalidPackets=0;
    for(const auto& c:snapshots)for(unsigned m=0;m<count;m++){
        const auto& f=c.frames[m];if(!f.completeCount)continue;
        auto* bytes=static_cast<const uint8_t*>(c.data.bytes)+f.offset;
        const auto bounded=std::min(f.completeCount,profile->inputCapacity);
        if(motu::inputPacketTimestampsValid(bytes,bounded,*profile))validPackets++;else invalidPackets++;
        NSMutableString* headers=[NSMutableString string];
        for(unsigned b=0;b+12<=bounded;b+=profile->inputBytes)[headers appendString:hex(bytes+b,12)];
        const bool full=(c.round==48&&c.slot==0);
        [packets addObject:@{@"data":(full?hex(bytes,profile->inputCapacity):@""),@"dataLength":@(c.data.length),@"offset":@(f.offset),@"phase":@(c.round?1:0),@"round":@(c.round),@"slot":@(c.slot),@"microframe":@(c.first*8+m),@"bytes":@(f.completeCount),@"status":@(uint32_t(f.status)),@"headers":headers}];
    }
    NSDictionary* report=@{@"primedSilence":@(primed),@"clockErrors":@(clockErrors),@"outputCompletions":@(outputCompletions),@"validPackets":@(validPackets),@"invalidPackets":@(invalidPackets),@"playbackEngineStarted":@(startPlayback),@"rate":@(rate),@"originalRate":@(originalProfile->rate),@"passed":@(ok&&stopped&&restored),@"stopped":@(stopped),@"restored":@(restored),@"commands":commands,@"packets":packets,@"error":error.description?:@""};
    NSData* json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');
    return ok&&stopped&&restored?0:1;
}}
