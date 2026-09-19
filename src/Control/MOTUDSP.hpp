#pragma once
#include "MOTUProtocol.hpp"
#include <stdint.h>
#include <stddef.h>
namespace motu {
constexpr uint32_t controlClientType=0x8280, controlVersion=1;
constexpr uint32_t dspCommandAddress=0x00010000, dspDestinationRegister=0xf0000b38;
struct DSPValue { uint32_t key=0,bits=0,kind=0,revision=0; };
static_assert(sizeof(DSPValue)==16);
constexpr uint32_t dspKey(unsigned section,unsigned block,unsigned parameter,unsigned channel) {
    return (section<<24)|(block<<16)|(parameter<<8)|channel;
}
float dspFloat(uint32_t bits);
uint32_t dspBits(float value);
// The cache contains only received values or acknowledged edits. No defaults
// are represented as hardware state. All access runs on the USB serial queue.
class DSPState {
public:
    static constexpr unsigned capacity=8192;
    DSPValue values[capacity]{};
    uint32_t revision=0,count=0,messages=0,errors=0;
    bool complete=false;
    bool update(uint32_t key,uint32_t bits,uint32_t kind);
    const DSPValue* find(uint32_t key) const;
    bool receive(const uint8_t* frame,size_t length);
    void resetParser();
    void clear();
    bool hasFullState() const;
private:
    uint8_t pending_[2048]{};
    size_t used_=0;
    uint8_t sequence_=0;
    bool sequenceKnown_=false;
};
class DSPMeters {
public:
    float values[400]{};
    uint32_t generation=0,count=0;
    void feed(uint8_t fragment);
private:
    float image_[400]{};
    uint64_t window_=0;
    uint32_t word_=0,index_=0;
    unsigned bytes_=0;
    bool synced_=false,valid_=true;
};
bool validDSPWrite(const DSPValue& value);
Command dspBlockWrite(uint8_t sequence,uint32_t address,const uint8_t* data,size_t length);
size_t dspEditFrame(uint8_t* out,size_t capacity,uint8_t sequence,const DSPValue& value);
}
