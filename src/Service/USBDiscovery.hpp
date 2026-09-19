#pragma once
namespace cute {
enum class DiscoveryResult { ready, busy, deviceAbsent, openFailed, invalidDescriptor, configurationReadFailed, unexpectedConfiguration, configureFailed, interfaceTimeout };
// Run only before streaming. Never reset an already configured device. IOUSBHost
// publishes child interfaces asynchronously, so discovery has a bounded wait.
template<class Operations> DiscoveryResult discoverUSBInterface(Operations& ops) {
    if(ops.driverPresent())return DiscoveryResult::busy;
    if(ops.findInterface())return DiscoveryResult::ready;
    const auto opened=ops.openDevice();
    if(opened!=DiscoveryResult::ready)return opened;
    if(!ops.validDescriptor())return DiscoveryResult::invalidDescriptor;
    int configuration=-1;
    if(!ops.readConfiguration(configuration))return DiscoveryResult::configurationReadFailed;
    if(configuration!=0 && configuration!=1)return DiscoveryResult::unexpectedConfiguration;
    if(configuration==0){
        if(ops.driverPresent())return DiscoveryResult::busy;
        if(!ops.configureOne())return DiscoveryResult::configureFailed;
    }
    for(unsigned i=0;i<100;i++){
        if(ops.driverPresent())return DiscoveryResult::busy;
        if(ops.findInterface())return DiscoveryResult::ready;
        ops.waitForInterface();
    }
    return DiscoveryResult::interfaceTimeout;
}
}
