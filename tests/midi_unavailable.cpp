// Link-only substitutes for the service startup regression. No USB is opened.
#include "MIDI.hpp"
#include <cstdlib>
namespace cute {
bool MIDI::open(){lastStatus=kMIDIServerStartErr;return false;}
void MIDI::close(){client=source=destination=0;writing.clear();dropped=0;}
void MIDI::drain(Backend&){}
void MIDI::receive(const motu::UMP&){}
std::unique_ptr<Backend> usbBackend(SharedAudio&,dispatch_queue_t){std::abort();}
}
