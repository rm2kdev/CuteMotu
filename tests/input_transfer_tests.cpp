#include "InputTransfer.hpp"
#include <cstdio>
#include <initializer_list>
#include <cstdlib>
using namespace cute;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);abort();}checks++;}while(0)
int main(){unsigned checks=0;
    for(const auto& p:motu::rateProfiles){
        const size_t capacity=128*p.inputCapacity;
        for(auto status:{kIOReturnSuccess,kIOReturnNotResponding,kIOReturnUnderrun,kIOReturnIsoTooOld,kIOReturnAborted,kIOReturnNoDevice}){
            const bool expected=status==kIOReturnSuccess || (p.multiplier>1 && (status==kIOReturnNotResponding || status==kIOReturnUnderrun));
            CHECK(usableInputCompletion(status,p)==expected);
            CHECK((inputTransaction(status,0,0,capacity,p)==InputTransaction::empty)==expected);
        }
        CHECK(inputTransaction(0,0,p.inputBytes,capacity,p)==InputTransaction::packet);
        CHECK(inputTransaction(kIOReturnUnderrun,0,p.inputPacketBytes(),capacity,p)==InputTransaction::packet);
        CHECK(inputTransaction(kIOReturnNotResponding,0,p.inputBytes,capacity,p)==InputTransaction::invalid);
        CHECK(inputTransaction(kIOReturnUnderrun,0,p.inputBytes,capacity,p)==InputTransaction::invalid);
        CHECK(inputTransaction(0,0,p.inputBytes-1,capacity,p)==InputTransaction::invalid);
        CHECK(inputTransaction(0,0,p.inputPacketBytes()+p.inputBytes,capacity,p)==InputTransaction::invalid);
        CHECK(inputTransaction(0,uint32_t(capacity-1),p.inputBytes,capacity,p)==InputTransaction::invalid);
        CHECK(inputTransaction(0,UINT32_MAX,0,capacity,p)==InputTransaction::invalid);
        // A high-rate completion can contain empty status-bearing microframes
        // followed by real whole PCM. Only the populated packets advance audio.
        if(p.multiplier>1){unsigned frames=0;
            for(unsigned m=0;m<128;m++){
                const auto status=m%2?kIOReturnSuccess:kIOReturnNotResponding;
                const auto bytes=m%2?p.inputPacketBytes():0;
                const auto result=inputTransaction(status,m*p.inputCapacity,bytes,capacity,p);
                CHECK(result!=InputTransaction::invalid);
                if(result==InputTransaction::packet)frames+=bytes/p.inputBytes;
            }
            CHECK(frames==64*p.packetSamples);
        }
    }
    printf("USB input completion/packet validation: %u checks passed\n",checks);
}
