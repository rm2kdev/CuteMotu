#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include "USBDiscovery.hpp"
#include "MOTUProtocol.hpp"
#include <chrono>
#include <thread>
namespace cute {
struct DeviceDiscovery {
    IOUSBHostDevice*& device;io_service_t& interfaceService;
    bool driverPresent(){
        for(const auto* name:{"MOTU828xDriver","MOTUUSBDevice"}){
            auto service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching(name));
            if(service){IOObjectRelease(service);return true;}
        }
        return false;
    }
    bool findInterface(){
        auto match=[IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x07fd productID:@2 bcdDevice:nil interfaceNumber:@0 configurationValue:@1 interfaceClass:@255 interfaceSubclass:@4 interfaceProtocol:@255 speed:nil productIDArray:nil];
        interfaceService=IOServiceGetMatchingService(kIOMainPortDefault,match);
        return interfaceService!=IO_OBJECT_NULL;
    }
    DiscoveryResult openDevice(){
        auto match=[IOUSBHostDevice createMatchingDictionaryWithVendorID:@0x07fd productID:@2 bcdDevice:nil deviceClass:@255 deviceSubclass:@4 deviceProtocol:nil speed:nil productIDArray:nil];
        auto service=IOServiceGetMatchingService(kIOMainPortDefault,match);
        if(!service)return DiscoveryResult::deviceAbsent;
        NSError* error=nil;
        device=[[IOUSBHostDevice alloc]initWithIOService:service options:IOUSBHostObjectInitOptionsNone queue:nil error:&error interestHandler:nil];
        IOObjectRelease(service);
        if(!device){fprintf(stderr,"Ordinary USB device open failed: %s\n",error.description.UTF8String);return DiscoveryResult::openFailed;}
        return DiscoveryResult::ready;
    }
    bool validDescriptor(){
        NSError* error=nil;const auto* descriptor=[device configurationDescriptorWithConfigurationValue:1 error:&error];
        if(!descriptor)return false;
        motu::Configuration parsed;
        return motu::parseConfiguration(reinterpret_cast<const uint8_t*>(descriptor),OSSwapLittleToHostInt16(descriptor->wTotalLength),parsed)==motu::Error::none && motu::validate828x(parsed)==motu::Error::none;
    }
    bool readConfiguration(int& value){
        // Use the host's configuration state, not a GET_CONFIGURATION request:
        // this 828x firmware returned timeout/overrun before being configured.
        auto property=IORegistryEntryCreateCFProperty(device.ioService,(CFStringRef)IOUSBHostDevicePropertyKeyCurrentConfiguration,kCFAllocatorDefault,0);
        if(property){
            const bool ok=CFGetTypeID(property)==CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)property,kCFNumberIntType,&value);
            CFRelease(property);return ok && value>=0 && value<=255;
        }
        // A fresh vendor-class device has neither an active configuration
        // property nor published child interfaces. Never reset existing ones.
        io_iterator_t children=IO_OBJECT_NULL;
        if(IORegistryEntryGetChildIterator(device.ioService,kIOServicePlane,&children)!=KERN_SUCCESS)return false;
        bool hasInterface=false;io_registry_entry_t child;
        while((child=IOIteratorNext(children))){if(IOObjectConformsTo(child,"IOUSBHostInterface"))hasInterface=true;IOObjectRelease(child);}
        IOObjectRelease(children);
        if(hasInterface)return false;
        value=0;return true;
    }
    bool configureOne(){
        NSError* error=nil;
        if(![device configureWithValue:1 matchInterfaces:YES error:&error]){
            fprintf(stderr,"SET_CONFIGURATION(1) failed: %s\n",error.description.UTF8String);return false;
        }
        fprintf(stderr,"Selected USB configuration 1; waiting for the 828x interface.\n");return true;
    }
    void waitForInterface(){std::this_thread::sleep_for(std::chrono::milliseconds(20));}
};
bool prepareUSBInterface(dispatch_queue_t,IOUSBHostDevice*& device,io_service_t& service){
    DeviceDiscovery operations{device,service};const auto result=discoverUSBInterface(operations);
    if(result==DiscoveryResult::ready)return true;
    const char* reason="unknown discovery error";
    switch(result){
        case DiscoveryResult::busy:reason="original MOTU driver is still attached; finish disabling it or reboot";break;
        case DiscoveryResult::deviceAbsent:reason="828x USB device absent; check its power and USB connection";break;
        case DiscoveryResult::openFailed:reason="828x present, but ordinary device open was denied; no capture/seize attempted";break;
        case DiscoveryResult::invalidDescriptor:reason="828x configuration descriptor did not validate";break;
        case DiscoveryResult::configurationReadFailed:reason="cannot read the current USB configuration";break;
        case DiscoveryResult::unexpectedConfiguration:reason="unexpected USB configuration; refusing to change it";break;
        case DiscoveryResult::configureFailed:reason="could not select USB configuration 1";break;
        case DiscoveryResult::interfaceTimeout:reason="828x present, but its interface did not appear within two seconds";break;
        case DiscoveryResult::ready:break;
    }
    fprintf(stderr,"USB discovery failed: %s\n",reason);
    if(device){[device destroy];[device release];device=nil;}
    return false;
}
}
