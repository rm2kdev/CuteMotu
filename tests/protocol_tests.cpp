#include "MOTUProtocol.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include <climits>
using namespace motu;
static unsigned checks = 0;
#define CHECK(x) do { ++checks; if (!(x)) { std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); std::exit(1); } } while (0)
static std::vector<uint8_t> fixture(const char* path) {
    std::ifstream f(path); std::string hex; f >> hex;
    CHECK(!hex.empty() && hex.size() % 2 == 0);
    std::vector<uint8_t> out;
    for (size_t i = 0; i < hex.size(); i += 2) out.push_back(uint8_t(std::stoul(hex.substr(i,2), nullptr,16)));
    return out;
}
int main(int argc, char** argv) {
    CHECK(argc == 2);
    auto bytes = fixture(argv[1]);
    Configuration c{};
    CHECK(parseConfiguration(bytes.data(),bytes.size(),c)==Error::none);
    CHECK(validate828x(c)==Error::none);
    CHECK(c.totalBytes==208 && c.alternateCount==5 && c.interfaceCount==1);
    CHECK(c.alternate(0)->endpointCount==2);
    CHECK(c.alternate(2)->endpoint(audioOut)->capacity()==1536);
    CHECK(c.alternate(3)->endpoint(audioIn)->capacity()==1920);
    CHECK(c.alternate(1)->endpoint(timingIn)->capacity()==4);
    // Every truncated prefix must be rejected, with an empty output object.
    for(size_t n=0;n<bytes.size();++n) { CHECK(parseConfiguration(bytes.data(),n,c)!=Error::none); CHECK(c.alternateCount==0); }
    auto bad=bytes;bad[9]=0;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::malformed);
    bad=bytes;bad[13]=3;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::malformed);
    bad=bytes;bad[27]=1;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::malformed);
    bad=bytes;bad[24]=0;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::malformed);
    bad=bytes;bad[60]=0x1b;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::malformed);
    bad=bytes;bad[12]=4;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::malformed);
    bad=bytes;bad[22]=128;CHECK(parseConfiguration(bad.data(),bad.size(),c)==Error::none);CHECK(validate828x(c)==Error::unsupported);
    auto command=readRegister(0x23,firmwareRegister);
    const std::array<uint8_t,6> expected={0x23,4,0,0,0,0xf0};
    CHECK(command.length==6);for(size_t i=0;i<6;++i)CHECK(command.bytes[i]==expected[i]);
    command=writeRegister(9,0x12345678,0xabcdef01);
    CHECK(command.length==12 && command.bytes[1]==0 && command.bytes[2]==0 && command.bytes[3]==0);
    CHECK(readLE32(command.bytes+4)==0x12345678 && readLE32(command.bytes+8)==0xabcdef01);
    // Synthetic replies independently assembled from the documented byte fields.
    std::array<uint8_t,12> response={0x23,6,0,0,0,0,0,0xf0,0x67,0x45,0x23,0x01};
    Reply reply{}; CHECK(parseReply(response.data(),response.size(),reply)==Error::none);
    CHECK(reply.value==0x01234567 && reply.address==firmwareRegister);
    CHECK(matchReadReply(reply,0x23,firmwareRegister)==Error::none);
    CHECK(matchReadReply(reply,0x24,firmwareRegister)==Error::wrongSequence);
    CHECK(matchReadReply(reply,0x23,guidRegister)==Error::wrongAddress);
    for(size_t n=0;n<12;++n)CHECK(parseReply(response.data(),n,reply)!=Error::none);
    // Observed mixed DSP heartbeat/register reply, including every transfer
    // split. Notifications may surround a reply or interrupt its USB framing.
    const uint8_t mixed[]={0x02,0xd3,0,0,0x79,6,0,0,0,0,0,0xf0,0,0x78,0x10,0,
        0xd4,1,4,0,0,0x44,0x44,0,2,0xd4,0,0};
    for(size_t split=0;split<=sizeof(mixed);split++) {
        RegisterReplyScanner scanner;scanner.begin(0x79,firmwareRegister,false);
        bool found=scanner.feed(mixed,split,reply);
        if(!found)found=scanner.feed(mixed+split,sizeof(mixed)-split,reply);
        CHECK(found && reply.value==0x107800 && reply.status==0);
    }
    RegisterReplyScanner scanner;scanner.begin(0x79,firmwareRegister,false);
    unsigned matches=0;
    for(auto byte:mixed)if(scanner.feed(&byte,1,reply)){matches++;CHECK(reply.value==0x107800);}
    CHECK(matches==1);
    scanner.begin(0x78,firmwareRegister,false);CHECK(!scanner.feed(mixed,sizeof(mixed),reply));
    scanner.begin(0x79,guidRegister,false);CHECK(!scanner.feed(mixed,sizeof(mixed),reply));
    scanner.begin(0x79,firmwareRegister,true);CHECK(!scanner.feed(mixed,sizeof(mixed),reply));
    const uint8_t ack[]={1,1,4,0,0,0x44,0x44,0,1,2,0,0,0,0,0xf0};
    for(size_t split=0;split<sizeof(ack);split++) {
        scanner.begin(1,firmwareRegister,true);
        bool found=scanner.feed(ack,split,reply);
        if(!found)found=scanner.feed(ack+split,sizeof(ack)-split,reply);
        CHECK(found && reply.operation==2 && reply.status==0);
    }
    scanner.begin(0x79,firmwareRegister,false);CHECK(!scanner.feed(mixed+4,8,reply));
    scanner.begin(0x79,firmwareRegister,false);CHECK(!scanner.feed(mixed+12,4,reply)); // reset discards partial reply
    CHECK(!scanner.feed(nullptr,1024,reply));
    ReadTransaction transaction;
    CHECK(!transaction.begin(1,0,UINT64_MAX-2,4));
    CHECK(transaction.begin(0x23,firmwareRegister,100,50));
    CHECK(!transaction.begin(0x24,guidRegister,100,50));
    response[0]=0x22;CHECK(transaction.receive(response.data(),12)==Error::wrongSequence);
    CHECK(transaction.state()==ReadTransaction::State::waiting);
    CHECK(!transaction.expire(149));CHECK(transaction.expire(150));
    response[0]=0x23;CHECK(transaction.receive(response.data(),12)==Error::unsupported);
    CHECK(transaction.begin(0x23,firmwareRegister,200,50));
    CHECK(transaction.receive(response.data(),12)==Error::none);CHECK(transaction.value()==0x01234567);
    transaction.cancel();CHECK(transaction.state()==ReadTransaction::State::idle);
    CHECK(transaction.begin(0x23,firmwareRegister,200,50));response[2]=1;
    CHECK(transaction.receive(response.data(),12)==Error::deviceStatus);
    CHECK(transaction.state()==ReadTransaction::State::failed);
    for(bool be:{false,true})for(int32_t value:{-8388608,-8388607,-1,0,1,8388606,8388607}) {
        uint8_t encoded[3];encode24(value,encoded,be);CHECK(decode24(encoded,be)==value);
    }
    uint8_t encoded[3];encode24(INT_MAX,encoded,true);CHECK(decode24(encoded,true)==8388607);
    encode24(INT_MIN,encoded,false);CHECK(decode24(encoded,false)==-8388608);
    const uint8_t negativeOne[]={0xff,0xff,0xff};CHECK(decode24(negativeOne,true)==-1);
    AudioLayout layout{12,4,2,0,true};
    uint8_t packet[]={0,0,0,1,0x7f,0xff,0xff,0x80,0,0,0,0};
    int32_t samples[2]{};size_t frames=999;
    CHECK(decodeAudioPacket(packet,sizeof(packet),layout,samples,2,frames)==Error::none);
    CHECK(frames==1 && samples[0]==8388607 && samples[1]==-8388608);
    CHECK(decodeAudioPacket(packet,11,layout,samples,2,frames)==Error::malformed && frames==0);
    CHECK(decodeAudioPacket(packet,12,layout,samples,1,frames)==Error::capacity);
    layout.pcmOffset=3;CHECK(validateLayout(layout)==Error::malformed);
    TimestampUnwrapper clock;uint64_t extended=0;
    CHECK(clock.push(0xfffffff0,extended));CHECK(clock.push(0x10,extended));CHECK(extended==0x100000010);
    CHECK(!clock.push(0x0f,extended));CHECK(clock.push(0x20,extended));CHECK(extended==0x100000020);
    clock.reset();CHECK(clock.push(4,extended) && extended==4);
    // Deterministic malformed-descriptor stress under ASan/UBSan.
    uint32_t rng=0x828;
    for(unsigned i=0;i<10000;++i) {
        bad=bytes;rng=rng*1664525+1013904223;size_t index=rng%bad.size();rng=rng*1664525+1013904223;bad[index]=uint8_t(rng>>24);
        auto e=parseConfiguration(bad.data(),bad.size(),c);
        if(e==Error::none) { CHECK(c.alternateCount<=16); for(unsigned j=0;j<c.alternateCount;++j) CHECK(c.alternates[j].endpointCount<=16); }
    }
    std::printf("PASS: %u assertions; observed USB fixture, protocol, PCM, clock and 10,000 malformed descriptor mutations.\n",checks);
}
