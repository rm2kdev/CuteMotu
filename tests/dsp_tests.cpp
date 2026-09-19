#include "MOTUDSP.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <limits>
using namespace motu;
static unsigned checks=0;
#define CHECK(x) do { if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);abort();}checks++; }while(0)
int main(){
 auto s=std::make_unique<DSPState>();
 // Captured protocol layout: single byte and little-endian IEEE float.
 uint8_t frame[]={2,0,0x69,1,0,1,0,2,0x66,0,2,0,2,0,0,0x80,0x3e,0x65,0,0};
 CHECK(s->receive(frame,sizeof(frame)));CHECK(s->complete);CHECK(s->count==2);
 CHECK(s->find(dspKey(2,0,1,0))->bits==1);
 CHECK(dspFloat(s->find(dspKey(2,0,2,0))->bits)==.25f);
 DSPValue v{dspKey(2,0,2,0),dspBits(.25f),4,0};uint8_t edit[12];
 CHECK(dspEditFrame(edit,sizeof(edit),1,v)==12);
 const uint8_t golden[]={2,1,0x66,0,2,0,2,0,0,0x80,0x3e,0};CHECK(!memcmp(edit,golden,12));
 CHECK(s->receive(edit,12));CHECK(s->count==2 && s->revision==2);
 auto packet=dspBlockWrite(9,dspCommandAddress,edit,12);
 const uint8_t prefix[]={9,1,12,0,0,0,1,0};CHECK(packet.length==20);CHECK(!memcmp(packet.bytes,prefix,8));
 CHECK(!dspBlockWrite(9,dspCommandAddress,edit,249).length);
 v.bits=dspBits(1.01f);CHECK(!validDSPWrite(v));v.bits=dspBits(std::numeric_limits<float>::quiet_NaN());CHECK(!validDSPWrite(v));
 v={dspKey(1,3,2,27),dspBits(1000),4,0};CHECK(validDSPWrite(v));v.key++;CHECK(!validDSPWrite(v));
 v={dspKey(1,0,11,0),2,1,0};CHECK(!validDSPWrite(v));
 // A multi-value command can span maximum-sized messages, including sequence wrap.
 uint8_t first[248]{2,255,0x46,64,0,3,2,1};
 uint8_t second[20]{2,0};uint8_t command[262]{0x46,64,0,3,2,1};
 for(unsigned i=0;i<64;i++)writeLE32(command+6+4*i,dspBits(float(i)));
 memcpy(first+2,command,246);memcpy(second+2,command+246,16);second[18]=0x65;
 s->resetParser();CHECK(s->receive(first,248));CHECK(s->receive(second,20));CHECK(s->complete);
 CHECK(dspFloat(s->find(dspKey(1,2,3,63))->bits)==63);
 first[1]=2;CHECK(!s->receive(first,248));CHECK(s->errors==1 && !s->complete);
 // USB 828x uses a heartbeat after its dump, without CMD_END.
 auto live=std::make_unique<DSPState>();uint8_t heartbeat[]={2,0,0,0};
 CHECK(live->receive(heartbeat,4));CHECK(!live->complete);
 CHECK(live->update(dspKey(0,0,0,0),dspBits(1),4));
 CHECK(live->update(dspKey(4,0,14,0),dspBits(1),4));
 for(unsigned i=0;i<28;i++)CHECK(live->update(dspKey(1,12,2,i),dspBits(0),4));
 for(unsigned i=0;i<15;i++)CHECK(live->update(dspKey(3,12,2,i),0,1));
 for(unsigned i=0;i<7;i++)CHECK(live->update(dspKey(2,29,6,i),dspBits(1),4));
 heartbeat[1]++;CHECK(live->receive(heartbeat,4));CHECK(!live->complete);
 CHECK(live->update(dspKey(2,29,6,7),dspBits(1),4));
 heartbeat[1]++;CHECK(live->receive(heartbeat,4));CHECK(live->complete);
 const auto rev=live->revision;live->clear();CHECK(!live->complete && !live->count && live->revision==rev);
 CHECK(!live->find(dspKey(0,0,0,0)));heartbeat[1]++;CHECK(live->receive(heartbeat,4));CHECK(!live->complete);
 CHECK(validDSPWrite({dspKey(2,0,0,0),255,1,0}));
 CHECK(!validDSPWrite({dspKey(2,0,0,0),15,1,0}));
 CHECK(validDSPWrite({dspKey(1,0,2,0),dspBits(24.90996f),4,0}));
 CHECK(!validDSPWrite({dspKey(1,0,2,0),dspBits(54),4,0}));
 CHECK(validDSPWrite({dspKey(3,9,2,0),dspBits(10),4,0}));
 CHECK(!validDSPWrite({dspKey(3,9,2,0),dspBits(20),4,0}));
 CHECK(!validDSPWrite({dspKey(3,9,5,0),dspBits(1),4,0}));
 CHECK(validDSPWrite({dspKey(1,3,2,0),dspBits(104.51563f),4,0}));
 // Meter images: little-endian floats between eight-FF delimiters.
 DSPMeters meter;for(unsigned i=0;i<8;i++)meter.feed(0xff);
 for(unsigned i=0;i<400;i++){auto word=dspBits(float(i)/400);for(unsigned b=0;b<4;b++)meter.feed(uint8_t(word>>(8*b)));}
 for(unsigned i=0;i<8;i++)meter.feed(0xff);
 CHECK(meter.generation==1 && meter.count==400);CHECK(meter.values[200]==.5f);
 // Corrupt values must not replace the last complete image.
 for(unsigned i=0;i<400;i++){auto word=dspBits(i==9?-1.f:.25f);for(unsigned b=0;b<4;b++)meter.feed(uint8_t(word>>(8*b)));}
 for(unsigned i=0;i<8;i++)meter.feed(0xff);CHECK(meter.generation==1 && meter.values[200]==.5f);
 // Unknown DSP telemetry must not freeze all audio meters when effects start.
 for(unsigned i=0;i<398;i++){auto word=dspBits(i==200?-48.f:i==201?std::numeric_limits<float>::quiet_NaN():.1f);for(unsigned b=0;b<4;b++)meter.feed(uint8_t(word>>(8*b)));}
 for(unsigned i=0;i<8;i++)meter.feed(0xff);
 CHECK(meter.generation==2 && meter.count==398 && meter.values[76]==.1f && meter.values[200]==-48.f);
 // Fill the bounded hash table and verify collision handling and capacity failure.
 auto table=std::make_unique<DSPState>();for(unsigned i=0;i<DSPState::capacity;i++)CHECK(table->update(i,i,1));
 for(unsigned i=0;i<DSPState::capacity;i++)CHECK(table->find(i)->bits==i);
 CHECK(!table->update(DSPState::capacity,1,1));CHECK(table->update(0,2,1));
 uint32_t seed=123;for(unsigned n=0;n<50000;n++){
  uint8_t raw[248];for(auto& b:raw){seed=1664525*seed+1013904223;b=seed>>24;}
  const size_t size=(seed%62+1)*4;s->resetParser();s->receive(raw,size);CHECK(s->count<=DSPState::capacity);
 }
 printf("PASS: %u DSP protocol, validation, cache, fragmentation and fuzz assertions\n",checks);
}
