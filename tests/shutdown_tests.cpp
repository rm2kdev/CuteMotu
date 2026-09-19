#include "MOTUShutdown.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <random>

int main() {
    using Gate=motu::ShutdownBarrier;
    unsigned checks=0;
    // Enumerate every subset of operations pending at close, and shuffled
    // callback orders. Neither a timer-first completion nor early USB aborts
    // may release resources or call superclass Stop while another is pending.
    std::mt19937 random(828);
    unsigned schedules=0;
    for (unsigned mask=0;mask<Gate::closing;mask++) {
        for (unsigned trial=0;trial<2;trial++) {
            Gate gate;
            assert(!gate.ready());
            assert(gate.begin(mask|Gate::closing));
            assert(!gate.begin(0)); // Repeated Stop cannot drop pending work.
            std::array<unsigned,Gate::operationCount+1> callbacks{};
            unsigned count=0;
            for (unsigned i=0;i<Gate::operationCount;i++) if (mask&(1u<<i)) callbacks[count++]=1u<<i;
            callbacks[count++]=Gate::closing;
            std::shuffle(callbacks.begin(),callbacks.begin()+count,random);
            for (unsigned i=0;i<count;i++) {
                assert(!gate.ready());
                gate.complete(callbacks[i]);
                gate.complete(callbacks[i]); // Duplicate notification is inert.
                assert(gate.ready()==(i+1==count));
                checks+=2;
            }
            assert(gate.ready());
            schedules++;
        }
    }
    std::printf("PASS: shutdown barrier, %u checks across %u callback schedules\n",checks,schedules);
}
