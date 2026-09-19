#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include "Backend.hpp"
#include "TransferLifetime.hpp"
#include "InputTransfer.hpp"
#include "USBRecovery.hpp"
#include "Client.hpp"
#include "TransportTiming.hpp"
#include <mach/mach_time.h>
#include <array>
#include <algorithm>
#include <cstring>
namespace cute {
bool prepareUSBInterface(dispatch_queue_t,IOUSBHostDevice*&,io_service_t&);
// All state and completions are serialized on the supplied dispatch queue.
// Buffers/transaction arrays live until their completion, even after abort.
class USB final:public Backend {
    static constexpr unsigned slots=usbQueueSlots,transactions=usbTransactionsPerTransfer;
    struct Transfer {NSMutableData* data=nil;std::array<IOUSBHostIsochronousTransaction,transactions> list{};uint64_t first=0;bool pending=false;};
    std::array<Transfer,slots> input{},output{};
    IOUSBHostDevice* deviceOwner=nil;IOUSBHostInterface* interface=nil;IOUSBHostPipe *controlIn=nil,*controlOut=nil,*audioIn=nil,*audioOut=nil;
    NSMutableData *readBuffer=nil,*writeBuffer=nil;
    dispatch_source_t timer=nullptr,recoveryTimer=nullptr;USBRecovery recovery;
    const motu::StreamProfile* profile=&motu::defaultProfile();
    motu::RegisterReplyScanner scanner;motu::StreamClock clock;motu::USBClockDecoder decoder;motu::USBHostClock hostClock;
    motu::MIDIQueue midiQueue;motu::MIDIEncoder midiEncoder;motu::MIDIParser midiParser;motu::MIDIPacer pacer;
    uint8_t sequence=0,dspSequence=0;uint32_t originalClock=0,clockWord=0;bool haveClock=false;
    TransferLifetime transfers;uint64_t lifecycle=0;uint64_t rx=0,tx=0,nextIn=0,nextOut=0,lastPacket=0,deadline=0,startDeadline=0,outputDone=0;
    uint64_t stableSince=0,settleNotBefore=0,repairWindow=0,acquisitionDiscards=0;unsigned repairsInWindow=0;
    bool readPending=false,writePending=false,commandPending=false,matched=false;
    bool stopping=false,restoring=false,closing=false,switching=false,warm=false,primed=false,running=false,runRequested=false,dspDisabled=false;
    unsigned dspStage=0;size_t dspUsed=0;uint8_t dspBytes[512]{};uint32_t commandValue=0;
    motu::DSPValue pendingEdit{};uint64_t pendingTicket=0;uint32_t retryRate=0;
    std::function<void(bool,uint32_t)> commandDone;std::function<void()> stopped;
    double ticks=ticksPerSecond();
    void later(double seconds,std::function<void()> f){const auto generation=lifecycle;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,int64_t(seconds*NSEC_PER_SEC)),queue,^{if(generation==lifecycle && !stopping && !closing)f();});}
    bool anyPending()const{return !transfers.empty();}
    void releasePipes(){[controlIn release];[controlOut release];[audioIn release];[audioOut release];controlIn=controlOut=audioIn=audioOut=nil;}
    bool pipes(bool audio){NSError* e=nil;controlIn=[interface copyPipeWithAddress:0x82 error:&e];controlOut=[interface copyPipeWithAddress:1 error:&e];
        if(audio){audioIn=[interface copyPipeWithAddress:0x84 error:&e];audioOut=[interface copyPipeWithAddress:3 error:&e];}
        return controlIn && controlOut && (!audio || (audioIn && audioOut));}
    void fail(const char* reason){if(stopping)return;fprintf(stderr,"USB stopped: %s\n",reason);audio.errors.fetch_add(1);
        recovery.failed(profile->rate,mach_absolute_time(),uint64_t(ticks));
        fprintf(stderr,"USB recovery queued at %u Hz (blocked rate %u).\n",recovery.safeRate(),recovery.blockedRate());drain([]{});}
    void watchRecovery(){if(recoveryTimer)return;
        recoveryTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
        dispatch_source_set_timer(recoveryTimer,DISPATCH_TIME_NOW,NSEC_PER_SEC,100*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(recoveryTimer,^{
            // Only a fully drained interface can be reopened. No completion or
            // transfer buffer from the previous session can survive this point.
            if(interface || anyPending())return;
            if(auto next=recovery.take(mach_absolute_time())){
                fprintf(stderr,"USB recovery opening at %u Hz.\n",next);
                if(!start(next))recovery.failed(next,mach_absolute_time(),uint64_t(ticks));
            }
        });dispatch_resume(recoveryTimer);
    }
    void completeCommand(bool ok){if(!commandPending)return;commandPending=false;auto done=std::move(commandDone);commandDone={};if(done)done(ok,commandValue);}
    void checkCommand(){if(commandPending && matched && !writePending)completeCommand(true);}
    void notifications(const uint8_t* bytes,size_t count){
        // Recover bounded complete notification envelopes, including fragmented
        // and concatenated transfers; register scanner independently finds ACKs.
        for(size_t n=0;n<count;n++){
            if(dspUsed==sizeof(dspBytes)){memmove(dspBytes,dspBytes+1,--dspUsed);}dspBytes[dspUsed++]=bytes[n];
            while(dspUsed>=8){
                if(dspBytes[1]!=1 || motu::readLE32(dspBytes+4)!=0x00444400 || dspBytes[2]>248 || dspBytes[2]<4 || dspBytes[2]%4){memmove(dspBytes,dspBytes+1,--dspUsed);continue;}
                size_t length=8+dspBytes[2];if(dspUsed<length)break;
                if(dspStage>=3 && !dspDisabled && !dsp.receive(dspBytes+8,length-8)){dspDisabled=true;controlStatus=0xe00002eb;}
                dspUsed-=length;memmove(dspBytes,dspBytes+length,dspUsed);
            }
        }
    }
    void read(){if(readPending || switching || closing || (stopping && !restoring) || !controlIn)return;
        if(!transfers.begin(TransferLifetime::read))return;readPending=true;NSError* e=nil;
        if(![controlIn enqueueIORequestWithData:readBuffer completionTimeout:0 error:&e completionHandler:^(IOReturn status,NSUInteger count){
            readPending=false;transfers.complete(TransferLifetime::read);
            if(stopping && !restoring){drained();return;}if(switching){selectAlternate();return;}
            if(status || count>readBuffer.length){if(restoring){closeAfterRestore();return;}fail("control read");return;}
            auto* bytes=static_cast<const uint8_t*>(readBuffer.bytes);notifications(bytes,count);
            if(commandPending){motu::Reply reply;if(scanner.feed(bytes,count,reply)){commandValue=reply.value;if(reply.status){completeCommand(false);}else matched=true;}}
            checkCommand();read();
        }]){readPending=false;transfers.complete(TransferLifetime::read);if(restoring)closeAfterRestore();else fail("control read submission");}
    }
    bool send(motu::Command c,uint32_t address,bool write,std::function<void(bool,uint32_t)> done){
        if(commandPending || writePending || !c.length || closing || (stopping && !restoring))return false;
        commandPending=true;matched=false;commandDone=std::move(done);deadline=mach_absolute_time()+uint64_t(ticks);scanner.begin(sequence,address,write);
        [writeBuffer setLength:c.length];memcpy(writeBuffer.mutableBytes,c.bytes,c.length);if(!transfers.begin(TransferLifetime::write)){completeCommand(false);return false;}writePending=true;read();if(closing || (stopping && !restoring)){writePending=false;transfers.complete(TransferLifetime::write);drained();return true;}NSError* e=nil;
        if(![controlOut enqueueIORequestWithData:writeBuffer completionTimeout:0 error:&e completionHandler:^(IOReturn status,NSUInteger count){
            writePending=false;transfers.complete(TransferLifetime::write);if(stopping && !restoring){drained();return;}
            if(status || count!=writeBuffer.length){completeCommand(false);return;}checkCommand();
        }]){writePending=false;transfers.complete(TransferLifetime::write);completeCommand(false);return true;}return true;
    }
    void reg(uint32_t address,bool write,uint32_t value,std::function<void(bool,uint32_t)> done){sequence=uint8_t(sequence%254+1);
        if(!send(write?motu::writeRegister(sequence,address,value):motu::readRegister(sequence,address),address,write,std::move(done)) && !stopping)fail("control command busy");}
    void firmware(unsigned attempt=0){reg(motu::firmwareRegister,false,0,[this,attempt](bool ok,uint32_t){if(!ok){if(!attempt && !writePending){firmware(1);return;}fail("firmware handshake");return;}
        reg(motu::clockRegister,false,0,[this](bool ok,uint32_t value){if(!ok || !motu::profileForClock(value)){fail("unsupported clock");return;}originalClock=value;haveClock=true;
            reg(motu::opticalRegister,false,0,[this](bool ok,uint32_t optical){if(!ok || !motu::supportedClock(originalClock,optical)){fail("requires internal clock and ADAT banks");return;}
                reg(motu::streamRegister,true,0x80800000,[this](bool ok,uint32_t){if(!ok){fail("stop before startup");return;}
                    clockWord=motu::rateClockWord(originalClock,*profile);
                    reg(motu::clockRegister,true,originalClock&~0x02000000u,[this](bool ok,uint32_t){if(!ok){fail("clear fetch");return;}
                        if(clockWord==(originalClock&~0x02000000u)){prepareAlternate();return;}
                        reg(motu::clockRegister,true,clockWord,[this](bool ok,uint32_t){if(!ok){fail("set rate");return;}later(2.5,[this]{prepareAlternate();});});
                    });
                });
            });
        });
    });}
    void prepareAlternate(){switching=true;[controlIn abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];selectAlternate();}
    void selectAlternate(){if(!switching || readPending || writePending || stopping)return;
        releasePipes();NSError* e=nil;const bool changed=interface.interfaceDescriptor->bAlternateSetting!=profile->alternate;
        if(changed && ![interface selectAlternateSetting:profile->alternate error:&e]){switching=false;fail("alternate setting");return;}
        switching=false;if(!pipes(true)){fail("stream pipes");return;}later(changed?0.01:0,[this]{beginInput();});
    }
    bool correlateHost(){
        IOUSBHostTime host=0;NSError* error=nil;
        const auto microframe=[interface currentMicroframeWithTime:&host error:&error];
        if(!microframe || !host || !hostClock.reference(microframe,host,ticks)){
            fprintf(stderr,"USB correlation rejected: microframe=%llu host=%llu error=%s\n",(unsigned long long)microframe,(unsigned long long)host,error.description.UTF8String);
            fail("USB host clock discontinuity");return false;
        }
        return true;
    }
    void beginInput(){IOUSBHostTime host=0;nextIn=[interface frameNumberWithTime:&host]+8;if(!correlateHost())return;
        for(unsigned i=0;i<slots;i++)if(!queueInput(i))return;warmWrite(0);}
    void warmWrite(unsigned attempt){reg(motu::streamRegister,true,0x00c00000,[this,attempt](bool ok,uint32_t){if(!ok){if(!attempt && !writePending){warmWrite(1);return;}fail("warm state");return;}warm=true;});}
    bool restartAcquisition(){
        // A sample origin can change only before any output has been queued.
        if(primed || audio.online.load() || mach_absolute_time()>startDeadline)return false;
        clock.reset();decoder={};rx=0;stableSince=0;audio.inputFrames=0;audio.epoch.fetch_add(1);return true;
    }
    void runStream(){runRequested=true;
        reg(motu::streamRegister,true,0xc0c00000,[this](bool ok,uint32_t){if(!ok){fail("run state");return;}
            reg(motu::clockRegister,true,clockWord|0x02000000u,[this](bool ok,uint32_t){if(!ok){fail("enable fetch");return;}
                running=true;settleNotBefore=mach_absolute_time()+uint64_t(2*ticks);stableSince=0;
                if(!primed)restartAcquisition();
            });});
    }
    void allocate(Transfer& t,size_t bytes){if(t.data)return;void* storage=nullptr;if(posix_memalign(&storage,16384,bytes))return;memset(storage,0,bytes);t.data=[[NSMutableData alloc]initWithBytesNoCopy:storage length:bytes freeWhenDone:YES];}
    bool queueInput(unsigned i){if(stopping)return false;auto& t=input[i];allocate(t,transactions*profile->inputCapacity);if(!t.data){fail("input allocation");return false;}
        t.first=nextIn;nextIn+=transactions/8;for(unsigned m=0;m<transactions;m++){t.list[m]={};t.list[m].offset=m*profile->inputCapacity;t.list[m].requestCount=profile->inputCapacity;}
        if(!transfers.begin(TransferLifetime::input(i)))return false;t.pending=true;NSError* e=nil;
        if(![audioIn enqueueIORequestWithData:t.data transactionList:t.list.data() transactionListCount:transactions firstFrameNumber:t.first options:IOUSBHostIsochronousTransferOptionsNone error:&e completionHandler:^(IOReturn s,IOUSBHostIsochronousTransaction*){
            auto& done=input[i];done.pending=false;transfers.complete(TransferLifetime::input(i));if(stopping){drained();return;}if(!usableInputCompletion(s,*profile)){
                fprintf(stderr,"USB input completion failed: status=%08x rate=%u first=%llu input=%llu\n",unsigned(s),profile->rate,(unsigned long long)done.first,(unsigned long long)rx);
                fail("input completion");return;}
            consume(done);if(!stopping)queueInput(i);
        }]){t.pending=false;transfers.complete(TransferLifetime::input(i));fprintf(stderr,"USB input submission failed: %s (first frame %llu)\n",e.description.UTF8String,(unsigned long long)t.first);fail("input submission");return false;}return true;
    }
    void consume(Transfer& t){
        if(!correlateHost())return;
        for(unsigned m=0;m<transactions;m++){
            auto& f=t.list[m];const auto disposition=inputTransaction(f.status,f.offset,f.completeCount,t.data.length,*profile);
            if(disposition==InputTransaction::invalid){fprintf(stderr,"USB invalid input transaction: status=%08x rate=%u microframe=%u offset=%u bytes=%u\n",unsigned(f.status),profile->rate,m,f.offset,f.completeCount);fail("invalid input packet");return;}
            if(disposition==InputTransaction::empty)continue;
            auto* p=static_cast<const uint8_t*>(t.data.bytes)+f.offset;
            uint32_t packetTick=motu::readBE32(p);bool repaired=false;
            if(!motu::inputPacketTimestampsValid(p,f.completeCount,*profile)){
                const auto now=mach_absolute_time();if(now-repairWindow>uint64_t(ticks)){repairWindow=now;repairsInWindow=0;}
                if(audio.online.load() && clock.locked() && repairsInWindow<8 && motu::recoverFirstTimestamp(p,f.completeCount,clock.timestamp(rx),packetTick,*profile)){repaired=true;repairsInWindow++;}
                else if(restartAcquisition()){acquisitionDiscards++;continue;}
                else {
                fprintf(stderr,"USB invalid timestamps: frame=%llu bytes=%u expected=%08x headers=",(unsigned long long)(t.first*8+m),f.completeCount,clock.locked()?clock.timestamp(rx):0);
                for(unsigned b=0;b+profile->inputBytes<=f.completeCount;b+=profile->inputBytes)fprintf(stderr,"%08x/%02x%02x ",motu::readBE32(p+b),p[b+4],p[b+5]);
                fprintf(stderr,"\n");fail("invalid input packet");return;
                }
            }
            decoder.beginPacket();bool discarded=false;
            for(unsigned b=repaired?profile->inputBytes:0;b<f.completeCount;b+=profile->inputBytes){motu::USBClockReference reference;
                if(decoder.feed(p+b,profile->inputBytes,t.first*8+m,reference) && !clock.reference(reference.tick,reference.microframe*7500,60000000.0)){
                    if(restartAcquisition()){acquisitionDiscards++;discarded=true;break;}fail("clock reference");return;}}
            if(discarded)continue;
            if(!clock.hasReference())continue;
            if(!clock.observe(packetTick,(t.first*8+m)*7500,rx,60000000.0)){
                if(restartAcquisition()){acquisitionDiscards++;continue;}fail("sample timestamp discontinuity");return;}
            for(unsigned b=0;b<f.completeCount;b+=profile->inputBytes){float pcm[maxChannels]{};uint8_t byte=0;bool has=false;
                if(motu::unpackFrame(p+b,profile->inputBytes,pcm,byte,has,*profile)!=motu::Error::none){fail("PCM validation");return;}
                if(repaired && !b){memset(pcm,0,sizeof(pcm));has=false;}else meters.feed(p[b+8]);
                audio.input.put(rx++,audio.epoch.load(),pcm,profile->inputs);
                motu::UMP message;if(has && midiParser.feed(byte,message) && midiInput)midiInput(message);
            }
            lastPacket=mach_absolute_time();
        }
        audio.inputFrames=rx;
        const auto now=mach_absolute_time();bool settled=false;
        if(warm && clock.locked()){
            if(!stableSince)stableSince=now;
            if(!runRequested && now-stableSince>=uint64_t(ticks/10)){
                if(profile->multiplier>1)prime();if(stopping)return;runStream();
            }
            settled=running && now>=settleNotBefore && now-stableSince>=uint64_t(ticks/2);
            if(settled && !primed)prime();if(stopping)return;
        }
        if(settled && outputDone>=slots && clock.locked()){
            const uint64_t deviceHost=clock.hostTime(rx);
            const auto mapTick=[this](uint64_t tick){auto m=tick/7500;auto h=hostClock.hostTime(m);auto next=hostClock.hostTime(m+1);return h+uint64_t(double(next-h)*double(tick%7500)/7500.0);};
            uint64_t mapped=mapTick(deviceHost);double period=ticks/profile->rate;
            const uint64_t future=clock.hostTime(rx+512);if(future>deviceHost){auto h=mapTick(future);if(h>mapped)period=double(h-mapped)/512;}
            audio.clock(rx,mapped,period);audio.heartbeat=lastPacket;if(!audio.online.exchange(1)){recovery.online(profile->rate);fprintf(stderr,"USB transport online at %u Hz (input %llu frames, output %llu frames queued; %llu startup packets discarded).\n",profile->rate,(unsigned long long)rx,(unsigned long long)tx,(unsigned long long)acquisitionDiscards);}
        }
    }
    void prime(){IOUSBHostTime host=0;nextOut=[interface frameNumberWithTime:&host]+8;const auto target=nextOut*8*7500;const auto receive=clock.hostTime(rx);
        if(target<receive){fail("output timeline");return;}tx=rx+uint64_t(std::ceil(double(target-receive)*profile->rate/60000000.0))+uint64_t(std::ceil(profile->rate*0.0005));
        primed=true;for(unsigned i=0;i<slots;i++)if(!queueOutput(i))return;
    }
    bool queueOutput(unsigned i){if(stopping)return false;auto& t=output[i];allocate(t,transactions*profile->outputCapacity);if(!t.data){fail("output allocation");return false;}
        t.first=nextOut;nextOut+=transactions/8;auto* bytes=static_cast<uint8_t*>(t.data.mutableBytes);uint32_t offset=0;
        for(unsigned m=0;m<transactions;m++){t.list[m]={};t.list[m].offset=offset;uint32_t count=0;
            if(motu::planOutputPacket(clock,(t.first*8+m+1)*7500+30000,tx,count)!=motu::Error::none || count*profile->outputBytes>profile->outputCapacity){fail("output packet plan");return false;}
            for(unsigned n=0;n<count;n++){float pcm[maxChannels]{};
                if(audio.online.load() && audio.audioActive.load() && !audio.output.get(tx,audio.epoch.load(),pcm,profile->outputs))audio.underruns.fetch_add(1);
                uint8_t byte=0;bool has=running && pacer.next(midiQueue,byte);
                if(motu::packFrame(bytes+offset,profile->outputBytes,pcm,clock.timestamp(tx++),has,byte,*profile)!=motu::Error::none){fail("output PCM");return false;}offset+=profile->outputBytes;
            }t.list[m].requestCount=count*profile->outputBytes;
        }
        if(!transfers.begin(TransferLifetime::output(i)))return false;t.pending=true;NSError* e=nil;
        if(![audioOut enqueueIORequestWithData:t.data transactionList:t.list.data() transactionListCount:transactions firstFrameNumber:t.first options:IOUSBHostIsochronousTransferOptionsNone error:&e completionHandler:^(IOReturn s,IOUSBHostIsochronousTransaction*){
            auto& done=output[i];done.pending=false;transfers.complete(TransferLifetime::output(i));if(stopping){drained();return;}if(s){fail("output completion");return;}
            for(const auto& f:done.list)if(f.status || f.completeCount!=f.requestCount){fail("output transaction");return;}
            outputDone++;audio.outputFrames=tx;queueOutput(i);
        }]){t.pending=false;transfers.complete(TransferLifetime::output(i));fprintf(stderr,"USB output submission failed: %s (first frame %llu, current %llu, bytes %u)\n",e.description.UTF8String,(unsigned long long)t.first,(unsigned long long)[interface frameNumberWithTime:nil],offset);fail("output submission");return false;}return true;
    }
    void abortPipes(){for(IOUSBHostPipe* p in @[controlIn?:[NSNull null],controlOut?:[NSNull null],audioIn?:[NSNull null],audioOut?:[NSNull null]])if((id)p!=[NSNull null])[p abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];}
    void closeAfterRestore(){restoring=false;closing=true;commandPending=false;commandDone={};transfers.drain();abortPipes();drained();}
    void drained(){if(!stopping || anyPending())return;
        if(!closing && haveClock && controlIn && controlOut){transfers.restart();restoring=true;
            reg(motu::streamRegister,true,0x80800000,[this](bool ok,uint32_t){if(!ok){closeAfterRestore();return;}
                reg(motu::clockRegister,true,originalClock&~0x02000000u,[this](bool,uint32_t){closeAfterRestore();});});return;}
        if(timer){dispatch_source_cancel(timer);dispatch_release(timer);timer=nullptr;}
        releasePipes();if(interface){[interface destroy];[interface release];interface=nil;}
        if(deviceOwner){[deviceOwner destroy];[deviceOwner release];deviceOwner=nil;}
        fprintf(stderr,"USB callbacks drained; interface closed (input %llu frames, output %llu frames queued, %llu output completions, %llu errors).\n",(unsigned long long)rx,(unsigned long long)tx,(unsigned long long)outputDone,(unsigned long long)audio.errors.load());
        for(auto& t:input){[t.data release];t.data=nil;}for(auto& t:output){[t.data release];t.data=nil;}
        [readBuffer release];[writeBuffer release];readBuffer=writeBuffer=nil;
        auto done=std::move(stopped);stopped={};if(done)done();
    }
    void dspSend(uint32_t address,const uint8_t* data,size_t size,std::function<void(bool)> done){sequence=uint8_t(sequence%254+1);
        if(!send(motu::dspBlockWrite(sequence,address,data,size),address,true,[done](bool ok,uint32_t){done(ok);}))done(false);}
    uint8_t nextDSP(){auto s=dspSequence;dspSequence=uint8_t((unsigned(s)+1)%255);return s;}
    void subscription(unsigned stage){dspStage=stage;
        const auto done=[this,stage](bool ok){if(!ok){dspDisabled=true;dsp.complete=false;controlStatus=0xe00002bc;return;}if(stage<3)subscription(stage+1);else dspStage=4;};
        if(stage==1){dsp.clear();const uint8_t address[]={0,0x44,0x44,0,0,0x44,0x44,0};dspSend(motu::dspDestinationRegister,address,8,done);}
        else {if(stage==3)dsp.resetParser();uint8_t message[]={uint8_t(stage==0?0:stage-1),nextDSP(),0,0};dspSend(motu::dspCommandAddress,message,4,done);}
    }
public:
    using Backend::Backend;
    const char* name()const override{return "IOUSBHost (live validation pending)";}
    bool start(uint32_t rate)override{
        watchRecovery();if(!transfers.restart())return false;lifecycle++;profile=motu::profileForRate(rate);if(!profile)return false;
        io_service_t service=IO_OBJECT_NULL;
        if(!prepareUSBInterface(queue,deviceOwner,service))return false;
        uint64_t registryID=0;io_registry_entry_t parent=IO_OBJECT_NULL;
        if(IORegistryEntryGetParentEntry(service,kIOServicePlane,&parent)==KERN_SUCCESS){IORegistryEntryGetRegistryEntryID(parent,&registryID);IOObjectRelease(parent);}recovery.connected(registryID);
        const auto generation=lifecycle;NSError* error=nil;interface=[[IOUSBHostInterface alloc]initWithIOService:service options:IOUSBHostObjectInitOptionsNone queue:queue error:&error interestHandler:^(IOUSBHostObject*,uint32_t type,void*){dispatch_async(queue,^{if(generation==lifecycle && !stopping && (type==kIOMessageServiceIsTerminated || type==kIOMessageServiceIsRequestingClose))fail("device interest/disconnect");});}];IOObjectRelease(service);
        if(!interface){fprintf(stderr,"ordinary interface open failed: %s\n",error.description.UTF8String);if(deviceOwner){[deviceOwner destroy];[deviceOwner release];deviceOwner=nil;}return false;}
        const auto* d=interface.configurationDescriptor;motu::Configuration config;
        if(!d || motu::parseConfiguration(reinterpret_cast<const uint8_t*>(d),OSSwapLittleToHostInt16(d->wTotalLength),config)!=motu::Error::none || motu::validate828x(config)!=motu::Error::none || !pipes(false)){releasePipes();[interface destroy];[interface release];interface=nil;if(deviceOwner){[deviceOwner destroy];[deviceOwner release];deviceOwner=nil;}return false;}
        readBuffer=[[NSMutableData alloc]initWithLength:256];writeBuffer=[[NSMutableData alloc]initWithLength:256];
        audio.online=0;audio.rate=rate;audio.epoch.fetch_add(1);audio.inputFrames=0;audio.outputFrames=0;
        rx=tx=nextIn=nextOut=outputDone=stableSince=settleNotBefore=repairWindow=acquisitionDiscards=0;repairsInWindow=0;haveClock=false;stopping=restoring=closing=switching=warm=primed=running=runRequested=dspDisabled=false;
        controlEpoch=mach_absolute_time();dspStage=0;dspUsed=0;dsp.clear();meters={};hostClock={};decoder={};clock.configure(*profile);pacer.configure(rate);midiQueue.discard();midiParser.reset();midiEncoder.reset();
        startDeadline=mach_absolute_time()+uint64_t(ticks*12);lastPacket=mach_absolute_time();
        timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);dispatch_source_set_timer(timer,DISPATCH_TIME_NOW,20*NSEC_PER_MSEC,NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer,^{if(generation!=lifecycle)return;auto now=mach_absolute_time();
            if(commandPending && now>deadline){if(writePending){if(restoring)closeAfterRestore();else fail("control timeout with pending write");}else completeCommand(false);}
            if(!stopping && ((!audio.online.load() && now>startDeadline) || (running && double(now-lastPacket)>ticks/4)))fail("stream watchdog");
        });dispatch_resume(timer);firmware();return true;
    }
    void drain(std::function<void()> done){if(stopping){if(!interface)done();else{auto previous=std::move(stopped);stopped=[previous,done]{if(previous)previous();done();};}return;}stopping=true;stopped=std::move(done);audio.online=0;dsp.complete=false;controlStatus=0xe00002d8;audio.epoch.fetch_add(1);
        commandPending=false;commandDone={};switching=false;transfers.drain();abortPipes();drained();}
    void stop(std::function<void()> done)override{
        recovery.cancel();if(recoveryTimer){dispatch_source_cancel(recoveryTimer);dispatch_release(recoveryTimer);recoveryTimer=nullptr;}drain(std::move(done));
    }
    bool setRate(uint32_t rate)override{if(stopping || !motu::profileForRate(rate) || !recovery.accepts(rate))return false;if(rate==profile->rate)return true;
        recovery.cancel();retryRate=rate;drain([this]{const auto rate=retryRate;if(!start(rate)){
            fprintf(stderr,"USB rate restart failed; recovery queued.\n");recovery.failed(rate,mach_absolute_time(),uint64_t(ticks));}});return true;}
    uint32_t safeRate()const override{return recovery.safeRate();}
    uint32_t blockedRate()const override{return recovery.blockedRate();}
    bool recoveryPending()const override{return recovery.pending();}
    uint32_t subscribe()override{if(!audio.online.load() || stopping)return 0xe00002d8;if(commandPending || writePending)return 0xe00002d5;
        dspDisabled=false;controlStatus=0;dsp.complete=false;subscription(0);return 0;}
    uint32_t edit(motu::DSPValue v,uint64_t& ticket)override{if(!audio.online.load() || dspDisabled || !dsp.complete || dspStage!=4)return 0xe00002d8;
        const auto* existing=dsp.find(v.key);if(!existing || existing->kind!=v.kind || !motu::validDSPWrite(v))return 0xe00002c2;
        if(commandPending || writePending)return 0xe00002d5;uint8_t frame[12];size_t n=motu::dspEditFrame(frame,sizeof(frame),nextDSP(),v);if(!n)return 0xe00002c2;
        pendingEdit=v;ticket=pendingTicket=nextTicket++;dspSend(motu::dspCommandAddress,frame,n,[this](bool ok){ack=pendingTicket;pendingTicket=0;controlStatus=ok?0:0xe00002bc;if(ok){dsp.update(pendingEdit.key,pendingEdit.bits,pendingEdit.kind);writes++;}else{dspDisabled=true;dsp.complete=false;}});return 0;}
    void midi(const uint32_t* words,size_t count)override{if(running && !stopping)midiEncoder.enqueue(words,count,midiQueue);}
};
std::unique_ptr<Backend> usbBackend(SharedAudio& a,dispatch_queue_t q){return std::make_unique<USB>(a,q);}
}
