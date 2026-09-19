#pragma once
#include <cstdint>
namespace cute {
// Ordinary userspace dispatch needs more headroom than the DriverKit baseline.
// Four 16-ms transfers keep 64 ms queued; HAL playback must arrive beyond that.
inline constexpr unsigned usbQueueSlots=4,usbTransactionsPerTransfer=128;
inline constexpr uint32_t usbQueueMilliseconds=usbQueueSlots*usbTransactionsPerTransfer/8;
inline constexpr double outputSafetySeconds=double(usbQueueMilliseconds+16)/1000;
inline constexpr double inputSafetySeconds=0.040;
static_assert(usbTransactionsPerTransfer%8==0 && usbQueueSlots==4);
}
