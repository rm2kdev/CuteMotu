#include "TransferLifetime.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
using cute::TransferLifetime;
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);abort();}checks++;}while(0)
int main(){unsigned long checks=0,schedules=0;std::array<unsigned,8> order={0,1,2,3,4,5,6,7};
    do{TransferLifetime t;CHECK(t.restart());auto generation=t.epoch();CHECK(t.current(generation));
        for(unsigned i=0;i<4;i++){CHECK(t.begin(t.input(i)));CHECK(t.begin(t.output(i)));CHECK(!t.begin(t.input(i)));}
        t.drain();CHECK(!t.empty());CHECK(!t.restart());CHECK(!t.current(generation));CHECK(!t.begin(t.read));
        for(unsigned i=0;i<8;i++){auto token=order[i]<4?t.input(order[i]):t.output(order[i]-4);CHECK(t.complete(token));CHECK(!t.complete(token));CHECK(t.empty()==(i==7));}
        CHECK(t.restart());CHECK(!t.current(generation));CHECK(t.current(t.epoch()));CHECK(t.begin(t.read));CHECK(t.begin(t.write));t.drain();CHECK(!t.empty());CHECK(t.complete(t.write));CHECK(!t.empty());CHECK(t.complete(t.read));CHECK(t.empty());schedules++;
    }while(std::next_permutation(order.begin(),order.end()));
    printf("USB lifetime ledger: %lu checks, %lu abort/completion schedules passed\n",checks,schedules);
}
