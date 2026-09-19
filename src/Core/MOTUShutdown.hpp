#pragma once
#include <stdint.h>

namespace motu {
// Accessed only on the service's serial queue. Each bit names an outstanding
// completion, including the synchronous close operation while it is in progress.
class ShutdownBarrier {
public:
    static constexpr uint32_t timer = 1u;
    static constexpr uint32_t read = 2u;
    static constexpr uint32_t write = 4u;
    static constexpr unsigned slotCount = 16;
    static constexpr unsigned operationCount = 3 + slotCount;
    static constexpr uint32_t closing = 1u << operationCount;
    static constexpr uint32_t isoch(unsigned slot) { return 1u << (3 + slot); }
    bool begin(uint32_t pending) {
        if (active_) return false;
        pending_ = pending;
        active_ = true;
        return true;
    }
    void complete(uint32_t operation) { if (active_) pending_ &= ~operation; }
    bool ready() const { return active_ && pending_ == 0; }
private:
    bool active_ = false;
    uint32_t pending_ = 0;
};
}
