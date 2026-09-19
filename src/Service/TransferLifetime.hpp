#pragma once
#include <cstdint>
namespace cute {
// Serial-queue ledger. Cancellation is NOT completion: a buffer remains in use
// until the corresponding callback retires its token. Generations invalidate
// delayed startup work after a drain/restart.
class TransferLifetime {
    uint32_t pending=0;uint64_t generation=0;bool draining=false;
public:
    enum:uint32_t {read=1,write=2};
    static constexpr uint32_t input(unsigned i){return i<4?1u<<(2+i):0;}
    static constexpr uint32_t output(unsigned i){return i<4?1u<<(6+i):0;}
    bool begin(uint32_t token){if(!token || token>output(3) || (token&(token-1)) || (pending&token) || draining)return false;pending|=token;return true;}
    bool complete(uint32_t token){if(!(pending&token))return false;pending&=~token;return true;}
    void drain(){draining=true;}
    bool empty()const{return pending==0;}
    bool restart(){if(pending)return false;draining=false;generation++;return true;}
    uint64_t epoch()const{return generation;}
    bool current(uint64_t value)const{return !draining && value==generation;}
};
}
