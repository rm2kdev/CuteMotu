#include "../src/HAL/ZeroTimeStamp.hpp"
#include <cassert>
#include <cstdio>
int main(){
    cute::ZeroTimeStampCache cache;cute::ZeroTimeStamp stamp;const auto p=cute::zeroTimeStampPeriod;
    static_assert(p>=10923);
    assert(cache.get({p,1000000,1},stamp));
    // USB phase corrections inside a period must not rewrite the last stamp.
    for(uint64_t correction=1;correction<10000;correction++){
        assert(cache.get({p,1000000+correction,1},stamp));assert(stamp.sample==p && stamp.host==1000000 && stamp.seed==1);
    }
    assert(cache.get({2*p,2000010,1},stamp));assert(stamp.sample==2*p && stamp.host==2000010);
    assert(cache.get({p,999999,1},stamp));assert(stamp.sample==2*p && stamp.host==2000010);
    // A real timeline change permits a new origin, including sample zero.
    assert(cache.get({0,3000000,2},stamp));assert(stamp.sample==0 && stamp.host==3000000 && stamp.seed==2);
    puts("Zero timestamps: minimum period, fixed repeated stamp, monotonic boundary and new-epoch reset passed");
}
