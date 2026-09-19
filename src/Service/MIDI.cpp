#include "MIDI.hpp"
#include <mach/mach_time.h>
namespace cute {
bool MIDI::open(){if((lastStatus=MIDIClientCreate(CFSTR("Cute Mix USB Audio Prototype"),nullptr,nullptr,&client))){close();return false;}
    if((lastStatus=MIDISourceCreateWithProtocol(client,CFSTR("Cute Mix USB DIN In"),kMIDIProtocol_1_0,&source))){close();return false;}
    if((lastStatus=MIDIDestinationCreateWithProtocol(client,CFSTR("Cute Mix USB DIN Out"),kMIDIProtocol_1_0,&destination,^(const MIDIEventList* list,void*){
        if(writing.test_and_set(std::memory_order_acquire)){dropped++;return;}
        const auto* p=&list->packet[0];unsigned total=0;
        for(unsigned i=0;i<list->numPackets && i<256;i++) {if(p->wordCount>256 || total+p->wordCount>1024){dropped++;break;}
            total+=p->wordCount;if(encoder.enqueue(p->words,p->wordCount,pending)!=motu::Error::none)dropped++;p=MIDIEventPacketNext(p);}
        writing.clear(std::memory_order_release);
    }))){close();return false;}
    MIDIObjectSetStringProperty(source,kMIDIPropertyManufacturer,CFSTR("Cute Mix"));MIDIObjectSetStringProperty(destination,kMIDIPropertyManufacturer,CFSTR("Cute Mix"));return true;
}
void MIDI::close(){if(client)MIDIClientDispose(client);client=source=destination=0;}
void MIDI::drain(Backend& backend){uint8_t byte;motu::UMP m;for(unsigned i=0;i<1024 && pending.pop(byte);i++)if(parser.feed(byte,m))backend.midi(m.words,m.count);}
void MIDI::receive(const motu::UMP& value){if(!source)return;MIDIEventList list{};auto* p=MIDIEventListInit(&list,kMIDIProtocol_1_0);if(MIDIEventListAdd(&list,sizeof(list),p,mach_absolute_time(),value.count,value.words))MIDIReceivedEventList(source,&list);}
}
