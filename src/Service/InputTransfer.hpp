#pragma once
#include "MOTURate.hpp"
#include <IOKit/IOReturn.h>
#include <cstddef>
namespace cute {
// The 828x high-bandwidth endpoint leaves some microframes unoccupied.
// The original DriverKit transport accepts these exact status/length pairs.
// An aggregate short-transfer status never excuses malformed populated packets.
inline bool usableInputCompletion(IOReturn status,const motu::StreamProfile& profile){
    return status==kIOReturnSuccess || (profile.multiplier>1 &&
        (status==kIOReturnNotResponding || status==kIOReturnUnderrun));
}
enum class InputTransaction {empty,packet,invalid};
inline InputTransaction inputTransaction(IOReturn status,uint32_t offset,uint32_t count,
                                         size_t capacity,const motu::StreamProfile& profile){
    if(offset>capacity || count>capacity-offset || count>profile.inputPacketBytes() || count%profile.inputBytes)
        return InputTransaction::invalid;
    const bool emptyHigh=profile.multiplier>1 && count==0 &&
        (status==kIOReturnNotResponding || status==kIOReturnUnderrun);
    const bool completeShort=status==kIOReturnUnderrun && count==profile.inputPacketBytes();
    if(status && !emptyHigh && !completeShort)return InputTransaction::invalid;
    return count?InputTransaction::packet:InputTransaction::empty;
}
}
