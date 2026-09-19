#import <Foundation/Foundation.h>
#include "Backend.hpp"
#include "MIDI.hpp"
#include "Client.hpp"
#include <SystemConfiguration/SystemConfiguration.h>
#include <sys/mman.h>
#include <pwd.h>
#include <signal.h>
#include <unistd.h>
#include <string>
#include <unordered_set>
using namespace cute;
int main(int argc,const char** argv){@autoreleasepool{
    bool usb=false,handover=false,midiEnabled=true,standalone=false;uint32_t rate=48000;std::string name=serviceName;
    for(int i=1;i<argc;i++){
        std::string a=argv[i];if(a=="--backend" && i+1<argc){std::string b=argv[++i];if(b!="usb" && b!="synthetic")return 2;usb=b=="usb";}
        else if(a=="--hardware-handover")handover=true;
        else if(a=="--standalone")standalone=true;
        else if(a=="--no-midi")midiEnabled=false;
        else if(a=="--rate" && i+1<argc){char* end=nullptr;auto n=strtoul(argv[++i],&end,10);if(!end || *end || n>UINT32_MAX || !motu::profileForRate(uint32_t(n)))return 2;rate=uint32_t(n);}
        else if(a=="--mach-service" && i+1<argc)name=argv[++i];
        else {fprintf(stderr,"Usage: cute-usb-service --backend synthetic|usb [--hardware-handover] [--rate Hz] [--mach-service name] [--no-midi] [--standalone]\n");return 2;}
    }
    if(usb && !handover){fprintf(stderr,"USB requires explicit --hardware-handover. No interface opened.\n");return 2;}
    auto queue=dispatch_queue_create("org.cutemix.usbaudio.service",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    const size_t regionBytes=(sizeof(SharedAudio)+16383)&~size_t(16383);
    void* region=mmap(nullptr,regionBytes,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);if(region==MAP_FAILED)return 1;
    auto* audio=new(region) SharedAudio();auto memory=xpc_shmem_create(region,regionBytes);if(!memory)return 1;
    auto backend=usb?usbBackend(*audio,queue):syntheticBackend(*audio,queue);Backend* engine=backend.get();
    __block bool started=false;dispatch_sync(queue,^{started=engine->start(rate);});if(!started)return 1;
    MIDI midi;const bool midiAvailable=midiEnabled && midi.open();
    if(midiEnabled && !midiAvailable)fprintf(stderr,"CoreMIDI endpoints unavailable (status %d); audio service continues without DIN MIDI.\n",int(midi.status()));
    auto* midiPtr=&midi;
    engine->midiInput=[midiPtr](const motu::UMP& m){midiPtr->receive(m);};
    auto midiTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);dispatch_source_set_timer(midiTimer,DISPATCH_TIME_NOW,NSEC_PER_MSEC,100000);
    dispatch_source_set_event_handler(midiTimer,^{midiPtr->drain(*engine);});dispatch_resume(midiTimer);
    auto* clients=new std::unordered_set<xpc_connection_t>();auto* owner=new xpc_connection_t(nullptr);
    auto listener=standalone?nullptr:xpc_connection_create_mach_service(name.c_str(),queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);if(!standalone && !listener)return 1;
    auto* ca=getpwnam("_coreaudiod");const uid_t audioUID=ca?ca->pw_uid:uid_t(-1);
    if(listener){xpc_connection_set_event_handler(listener,^(xpc_object_t event){
        if(xpc_get_type(event)!=XPC_TYPE_CONNECTION){fprintf(stderr,"Mach listener unavailable (launch with launchd)\n");exit(1);}
        auto peer=(xpc_connection_t)event;uid_t consoleUID=uid_t(-1);auto console=SCDynamicStoreCopyConsoleUser(nullptr,&consoleUID,nullptr);if(console)CFRelease(console);
        const uid_t uid=xpc_connection_get_euid(peer);
        if(clients->size()>=16 || !(uid==geteuid() || uid==0 || uid==consoleUID || uid==audioUID)){xpc_connection_cancel(peer);return;}
        clients->insert(peer);xpc_retain(peer);xpc_connection_set_target_queue(peer,queue);
        xpc_connection_set_event_handler(peer,^(xpc_object_t request){
            if(xpc_get_type(request)==XPC_TYPE_ERROR){if(*owner==peer){*owner=nullptr;audio->audioActive=0;audio->epoch.fetch_add(1);}if(clients->erase(peer))xpc_release(peer);return;}
            if(xpc_get_type(request)!=XPC_TYPE_DICTIONARY)return;
            auto reply=xpc_dictionary_create_reply(request);if(!reply)return;
            uint32_t error=0;const char* op=xpc_dictionary_get_string(request,"op");
            if(xpc_dictionary_get_uint64(request,"version")!=abiVersion || !op)error=0xe00002c2;
            else if(!strcmp(op,"hello")){
                const char* role=xpc_dictionary_get_string(request,"role");
                if(!role || (strcmp(role,"audio") && strcmp(role,"control")))error=0xe00002c2;
                else if(!strcmp(role,"audio")){
                    if(!(uid==geteuid() || uid==0 || uid==audioUID))error=0xe00002c1;
                    else if(*owner && *owner!=peer)error=0xe00002d5;
                    else{if(!*owner){audio->audioActive=0;audio->epoch.fetch_add(1);}*owner=peer;xpc_dictionary_set_value(reply,"memory",memory);}
                }
            }else if(!strcmp(op,"status")){
                xpc_dictionary_set_string(reply,"backend",engine->name());xpc_dictionary_set_bool(reply,"online",audio->online.load());
                xpc_dictionary_set_uint64(reply,"safeRate",engine->safeRate());xpc_dictionary_set_uint64(reply,"blockedRate",engine->blockedRate());xpc_dictionary_set_bool(reply,"recoveryPending",engine->recoveryPending());
                xpc_dictionary_set_uint64(reply,"rate",audio->rate.load());xpc_dictionary_set_uint64(reply,"epoch",audio->epoch.load());
                xpc_dictionary_set_uint64(reply,"inputFrames",audio->inputFrames.load());xpc_dictionary_set_uint64(reply,"outputFrames",audio->outputFrames.load());
                xpc_dictionary_set_uint64(reply,"underruns",audio->underruns.load());xpc_dictionary_set_uint64(reply,"errors",audio->errors.load());
                xpc_dictionary_set_bool(reply,"midiAvailable",midiAvailable);
                xpc_dictionary_set_int64(reply,"midiStatus",midiEnabled?midiPtr->status():0);
                xpc_dictionary_set_bool(reply,"sipOnValidated",false);
            }else if(!strcmp(op,"rate")){
                auto n=xpc_dictionary_get_uint64(request,"rate");
                if(*owner!=peer || n>UINT32_MAX || !motu::profileForRate(uint32_t(n)))error=0xe00002c2;
                else if(!engine->setRate(uint32_t(n)))error=0xe00002d5;
            }else if(!strcmp(op,"subscribe")){error=engine->subscribe();}
            else if(!strcmp(op,"edit")){
                size_t length=0;auto p=xpc_dictionary_get_data(request,"value",&length);
                if(length!=sizeof(motu::DSPValue))error=0xe00002c2;
                else {motu::DSPValue v;memcpy(&v,p,sizeof(v));uint64_t ticket=0;error=engine->edit(v,ticket);xpc_dictionary_set_uint64(reply,"ticket",ticket);}
            }else if(!strcmp(op,"snapshot")){
                const auto after=xpc_dictionary_get_uint64(request,"after");motu::DSPValue entries[motu::DSPState::capacity];size_t count=0;
                if(after>UINT32_MAX)error=0xe00002c2;
                else {for(const auto& v:engine->dsp.values)if(v.kind && v.revision>after)entries[count++]=v;
                    const uint64_t s[]={engine->dsp.complete,engine->dsp.revision,engine->ack,engine->controlStatus,engine->dsp.messages,engine->dsp.errors,engine->writes,engine->dsp.count,engine->controlEpoch};
                    xpc_dictionary_set_data(reply,"values",entries,count*sizeof(entries[0]));xpc_dictionary_set_data(reply,"state",s,sizeof(s));}
            }else if(!strcmp(op,"meters")){
                xpc_dictionary_set_data(reply,"values",engine->meters.values,sizeof(engine->meters.values));xpc_dictionary_set_uint64(reply,"generation",engine->meters.generation);xpc_dictionary_set_uint64(reply,"count",engine->meters.count);
            }else error=0xe00002c7;
            xpc_dictionary_set_uint64(reply,"version",abiVersion);xpc_dictionary_set_uint64(reply,"status",error);xpc_connection_send_message(peer,reply);xpc_release(reply);
        });xpc_connection_resume(peer);
    });xpc_connection_resume(listener);}
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
    for(int sig:{SIGTERM,SIGINT}){auto source=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig,0,queue);dispatch_source_set_event_handler(source,^{
        if(listener)xpc_connection_cancel(listener);dispatch_source_cancel(midiTimer);engine->stop([]{exit(0);});
    });dispatch_resume(source);}
    fprintf(stderr,"Cute Mix service: %s at %u Hz; SIP-on validation pending\n",engine->name(),rate);dispatch_main();
}}
