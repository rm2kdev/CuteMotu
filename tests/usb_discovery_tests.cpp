#include "USBDiscovery.hpp"
#include <cstdio>
#include <cstdlib>
using namespace cute;
struct Fake {
    bool busy=false,present=true,valid=true,readable=true,configureOK=true;
    DiscoveryResult openResult=DiscoveryResult::ready;
    int configuration=0,appearsAfter=0,waits=0,opens=0,sets=0,driverChecks=0,becomesBusyAt=0;
    bool driverPresent(){return busy || (becomesBusyAt && ++driverChecks>=becomesBusyAt);}
    bool findInterface(){return present && waits>=appearsAfter;}
    DiscoveryResult openDevice(){opens++;return openResult;}
    bool validDescriptor(){return valid;}
    bool readConfiguration(int& n){n=configuration;return readable;}
    bool configureOne(){sets++;return configureOK;}
    void waitForInterface(){waits++;}
};
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);abort();}checks++;}while(0)
int main(){unsigned checks=0;Fake f;
    CHECK(discoverUSBInterface(f)==DiscoveryResult::ready);CHECK(!f.opens && !f.sets);
    f={};f.appearsAfter=3;CHECK(discoverUSBInterface(f)==DiscoveryResult::ready);CHECK(f.opens==1 && f.sets==1 && f.waits==3);
    f={};f.appearsAfter=3;f.configuration=1;CHECK(discoverUSBInterface(f)==DiscoveryResult::ready);CHECK(f.opens==1 && f.sets==0);
    f={};f.busy=true;CHECK(discoverUSBInterface(f)==DiscoveryResult::busy);CHECK(!f.opens && !f.sets);
    f={};f.present=false;f.openResult=DiscoveryResult::deviceAbsent;CHECK(discoverUSBInterface(f)==DiscoveryResult::deviceAbsent);CHECK(!f.sets);
    f={};f.present=false;f.openResult=DiscoveryResult::openFailed;CHECK(discoverUSBInterface(f)==DiscoveryResult::openFailed);CHECK(!f.sets);
    f={};f.present=false;f.valid=false;CHECK(discoverUSBInterface(f)==DiscoveryResult::invalidDescriptor);CHECK(!f.sets);
    f={};f.present=false;f.readable=false;CHECK(discoverUSBInterface(f)==DiscoveryResult::configurationReadFailed);CHECK(!f.sets);
    f={};f.present=false;f.configuration=2;CHECK(discoverUSBInterface(f)==DiscoveryResult::unexpectedConfiguration);CHECK(!f.sets);
    f={};f.present=false;f.configureOK=false;CHECK(discoverUSBInterface(f)==DiscoveryResult::configureFailed);CHECK(f.sets==1);
    f={};f.present=false;CHECK(discoverUSBInterface(f)==DiscoveryResult::interfaceTimeout);CHECK(f.sets==1 && f.waits==100);
    f={};f.present=false;f.becomesBusyAt=2;CHECK(discoverUSBInterface(f)==DiscoveryResult::busy);CHECK(!f.sets);
    f={};f.appearsAfter=4;f.becomesBusyAt=4;CHECK(discoverUSBInterface(f)==DiscoveryResult::busy);CHECK(f.sets==1 && f.waits==1);
    printf("USB discovery: %u checks passed (cold boot, existing configuration, ownership races, bounded publication wait).\n",checks);
}
