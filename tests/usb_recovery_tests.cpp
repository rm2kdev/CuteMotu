#include "USBRecovery.hpp"
#include <cstdio>
#include <cstdlib>
using cute::USBRecovery;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);abort();}checks++;}while(0)
int main(){unsigned checks=0;USBRecovery p;
    p.connected(100);p.online(44100);p.failed(88200,10000,1000);
    CHECK(p.pending());CHECK(p.safeRate()==44100);CHECK(!p.accepts(88200));CHECK(p.accepts(44100));
    CHECK(p.take(10999)==0);CHECK(p.take(11000)==44100);CHECK(!p.pending());CHECK(p.take(12000)==0);
    // Restoring the previous rate must not retry Core Audio's saved failing rate.
    p.connected(100);p.online(44100);CHECK(!p.accepts(88200));CHECK(p.blockedRate()==88200);
    // A deliberate different base rate or a new physical device allows a retry.
    p.online(48000);CHECK(p.accepts(88200));p.failed(88200,20000,1000);p.online(48000);CHECK(!p.accepts(88200));
    p.connected(101);CHECK(p.accepts(88200));
    p.online(88200);CHECK(p.safeRate()==48000);p.failed(88200,30000,1000);CHECK(p.take(31000)==48000);
    // Reconnect polling backs off to 30 seconds; shutdown cancels pending work.
    USBRecovery unplug;uint64_t now=100000;const unsigned delays[]={1,2,4,8,16,30,30,30};
    for(auto seconds:delays){unplug.failed(48000,now,1000);CHECK(unplug.take(now+seconds*1000-1)==0);CHECK(unplug.take(now+seconds*1000)==48000);now+=seconds*1000;}
    unplug.failed(48000,now,1000);unplug.cancel();CHECK(!unplug.pending());CHECK(unplug.take(UINT64_MAX)==0);
    puts("USB recovery: failed-rate fallback, saved-rate guard, reconnect, bounded backoff and shutdown passed");
    printf("%u recovery checks passed\n",checks);
}
