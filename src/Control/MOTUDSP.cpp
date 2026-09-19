#include "MOTUDSP.hpp"
#include <string.h>
#include <math.h>
namespace motu {
float dspFloat(uint32_t bits) { float f; memcpy(&f,&bits,4);return f; }
uint32_t dspBits(float f) { uint32_t b;memcpy(&b,&f,4);return b; }
static unsigned slot(uint32_t key) { return (key*2654435761u)>>(32-13); }
const DSPValue* DSPState::find(uint32_t key) const {
    for (unsigned n=0,i=slot(key);n<capacity;n++,i=(i+1)%capacity) {
        const auto& v=values[i]; if (!v.kind) return nullptr; if (v.key==key) return &v;
    }
    return nullptr;
}
bool DSPState::update(uint32_t key,uint32_t bits,uint32_t kind) {
    if ((kind!=1 && kind!=4) || (kind==4 && !isfinite(dspFloat(bits)))) return false;
    for (unsigned n=0,i=slot(key);n<capacity;n++,i=(i+1)%capacity) {
        auto& v=values[i];
        if (!v.kind || v.key==key) {
            if (!v.kind) count++;
            if (v.kind!=kind || v.bits!=bits) v={key,bits,kind,++revision};
            return true;
        }
    }
    return false;
}
void DSPState::resetParser() { used_=0;sequenceKnown_=false;complete=false; }
void DSPState::clear() { memset(values,0,sizeof(values));count=0;resetParser(); }
bool DSPState::hasFullState() const {
    if(!find(dspKey(0,0,0,0)) || !find(dspKey(4,0,14,0)))return false;
    for(unsigned ch=0;ch<28;ch++)if(!find(dspKey(1,12,2,ch)))return false;
    for(unsigned ch=0;ch<15;ch++)if(!find(dspKey(3,12,2,ch)))return false;
    for(unsigned ch=0;ch<8;ch++)if(!find(dspKey(2,29,6,ch)))return false;
    return true;
}
bool DSPState::receive(const uint8_t* p,size_t n) {
    if (!p || n<4 || n>248 || n%4) { errors++;resetParser();return false; }
    if (sequenceKnown_ && p[1]!=sequence_) { errors++;resetParser();return false; }
    sequenceKnown_=true;sequence_=uint8_t(p[1]+1);messages++;
    // The 828x USB dump ends with padding, followed by active sensing rather
    // than CMD_END. Require the final field of every channel family, a clean
    // command boundary, and the subsequent heartbeat before allowing writes.
    if(n==4 && !p[2] && !p[3] && !used_ && hasFullState())complete=true;
    if (used_+n-2>sizeof(pending_)) { errors++;resetParser();return false; }
    memcpy(pending_+used_,p+2,n-2);used_+=n-2;
    size_t offset=0;
    while (offset<used_) {
        const uint8_t* c=pending_+offset;size_t remain=used_-offset,length=0;unsigned kind=0,countValues=1;
        if (!c[0] || c[0]==0x65) { complete=complete || c[0]==0x65;offset=used_;break; }
        if (c[0]==0x62) { offset++;continue; }
        if (c[0]==0x23) { if (remain<6) break;offset+=6;continue; }
        if (c[0]==0x69) { kind=1;length=6; }
        else if (c[0]==0x66) { kind=4;length=9; }
        else if (c[0]==0x49 || c[0]==0x46) {
            if (remain<2) break;kind=c[0]==0x49?1:4;countValues=c[1];length=6+kind*countValues;
        } else { errors++;resetParser();return false; }
        if (remain<length) break;
        const uint8_t* id=c+(c[0]==0x66?1:2);
        for (unsigned i=0;i<countValues;i++) {
            const bool multiple=c[0]==0x49 || c[0]==0x46;
            const auto channel=multiple?i:id[0];
            const uint8_t* data=multiple?c+6+i*kind:c+(kind==4?5:1);
            if (id[3]<=4 && !update(dspKey(id[3],id[2],id[1],channel),kind==4?readLE32(data):*data,kind)) {
                errors++;resetParser();return false;
            }
        }
        offset+=length;
    }
    used_-=offset; if (used_) memmove(pending_,pending_+offset,used_);
    if (n<248 && used_) { errors++;resetParser();return false; }
    return true;
}
void DSPMeters::feed(uint8_t byte) {
    window_=(window_>>8)|(uint64_t(byte)<<56);
    if(window_==UINT64_MAX) {
        // Two all-ones words delimit each meter image. They are not levels.
        if(synced_ && valid_ && index_>=1 && index_<=401) {
            count=index_-1;
            if(count>0 && count<=400){memcpy(values,image_,count*sizeof(float));generation++;}
        }
        synced_=true;valid_=true;word_=0;bytes_=0;index_=0;return;
    }
    if(!synced_)return;
    word_|=uint32_t(byte)<<(8*bytes_++);
    if(bytes_==4) {
        // All-ones terminator words are recognized by the rolling delimiter.
        if(index_<400 && word_!=UINT32_MAX) {
            const float level=dspFloat(word_);
            // Only the first 104 slots are audio peak meters on the 828x.
            // The following DSP telemetry may contain signed quantities or
            // nonfinite sentinels when an effect has no input. Preserve those
            // raw words without discarding the usable audio meter image.
            if(index_<104 && (!isfinite(level) || level<0 || level>16))valid_=false;
            image_[index_]=level;
        }
        index_++;bytes_=0;word_=0;
        if(index_>402){synced_=false;valid_=false;}
    }
}
static bool range(const DSPValue& v,float lo,float hi,bool integer=false) {
    const float x=v.kind==1?float(v.bits):dspFloat(v.bits);
    return isfinite(x) && x>=lo && x<=hi && (!integer || floorf(x)==x);
}
bool validDSPWrite(const DSPValue& v) {
    const unsigned section=v.key>>24,block=(v.key>>16)&255,param=(v.key>>8)&255,ch=v.key&255;
    auto byte=[&](unsigned max=1){return v.kind==1 && v.bits<=max;};
    auto number=[&](float lo,float hi,bool integer=false){return v.kind==4 && range(v,lo,hi,integer);};
    if (section==0 && ch==0 && block==0) {
        if (param==0 || param==5 || param==6) return number(0,1);
        if (param==1 || param==2) return byte();
        if (param==8) return byte(14);
        if (param==3 || param==4) return v.kind==1 && (v.bits<28 || v.bits==255);
        return false;
    }
    if (section==2 && ch<8) {
        if (block==0) { if(param==0)return v.kind==1 && (v.bits<15 || v.bits==255);if(param==1)return byte();if(param==2)return number(0,1); }
        if (block==1 && param<2) return number(0,1);
        if (block>=2 && block<30) {
            if(param<2)return byte();if(param==4)return byte(1);
            if(param==3)return number(0,1);
            if(param==2 || param==5 || param==6)return number(-1,1);
        }
        return false;
    }
    if (section==4 && ch==0 && block==0) {
        if(param==0 || param==1)return byte();if(param==12)return byte(4);
        if(param==2)return number(0,100);
        if(param==3)return number(1000,20000);
        if(param==4)return number(-40,0);
        if(param==5)return number(100,60000);
        if(param>=6 && param<=8)return number(0,100);
        if(param==9 || param==10)return number(100,20000);
        if(param==11)return number(-1,1);
        if(param==13)return number(50,400);
        if(param==14)return number(0,1);
        return false;
    }
    if ((section!=1 && section!=3) || ch>=(section==1?28u:15u))return false;
    if(section==1 && block==0) {
        if(param==2)return ch<2?number(0,53):ch<10?number(-96,22):number(0,12);
        if(param==5)return number(0,1);
        if(param<=11)return byte();return false;
    }
    // Input EQ starts one block after output EQ.
    const unsigned b=block+(section==3?1:0);
    if(b==1 || b==9)return param==0 && byte();
    if(b==2 || b==8) {
        if(param==0)return byte();if(param==1)return byte(5);if(param==2)return number(20,20000);
    }
    if(b>=3 && b<=7) {
        if(param==0)return byte();if(param==1)return byte(b==3 || b==7?4:3);
        if(param==2)return number(20,20000);if(param==3)return number(-20,20);if(param==4)return number(0.01f,3);
    }
    if(b==10) {
        if(param==0 || param==6)return byte();if(param==1)return number(-48,0);
        if(param==2)return number(1,10);
        if(param==3)return number(10,100);if(param==4)return number(10,1000);
        if(param==5)return number(-6,0);
    }
    if(b==11) { if(param<2)return byte();if(param<4)return number(0,100); }
    if(b==12) { if(param<2)return number(0,1);if(section==1 && param==2)return number(-1,1); }
    if(section==3 && block==12 && param<3)return byte();
    return false;
}
Command dspBlockWrite(uint8_t sequence,uint32_t address,const uint8_t* data,size_t n) {
    Command c{};if(!data || !n || n>248)return c;
    c.bytes[0]=sequence;c.bytes[1]=1;c.bytes[2]=uint8_t(n);writeLE32(c.bytes+4,address);
    memcpy(c.bytes+8,data,n);c.length=uint16_t(n+8);return c;
}
size_t dspEditFrame(uint8_t* p,size_t n,uint8_t sequence,const DSPValue& v) {
    if(!p || n<12 || !validDSPWrite(v))return 0;memset(p,0,12);p[0]=2;p[1]=sequence;
    const unsigned start=v.kind==4?3:4;p[2]=v.kind==4?0x66:0x69;
    for(unsigned i=0;i<4;i++)p[start+i]=uint8_t(v.key>>(8*i));
    if(v.kind==4)writeLE32(p+7,v.bits);else p[3]=uint8_t(v.bits);
    return v.kind==4?12:8;
}
}
