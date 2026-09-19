#pragma once
#include "Backend.hpp"
#include <CoreMIDI/CoreMIDI.h>
#include <atomic>
namespace cute {
class MIDI {
    MIDIClientRef client=0;MIDIEndpointRef source=0,destination=0;
    OSStatus lastStatus=0;
    // CoreMIDI callbacks only put into a bounded queue. USB serial queue drains it.
    motu::MIDIQueue pending;motu::MIDIEncoder encoder;motu::MIDIParser parser;
    std::atomic_flag writing=ATOMIC_FLAG_INIT;std::atomic<uint64_t> dropped{0};
public:
    bool open();void close();void drain(Backend& backend);void receive(const motu::UMP& value);
    OSStatus status()const{return lastStatus;}
    ~MIDI(){close();}
};
}
