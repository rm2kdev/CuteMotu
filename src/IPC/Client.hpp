#pragma once
#include "SharedAudio.hpp"
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <memory>
#include <mutex>
#include <vector>
namespace cute {
struct Mapping {
    void* address=nullptr;size_t size=0;
    explicit Mapping(xpc_object_t object);
    ~Mapping();
    SharedAudio* get() const {return static_cast<SharedAudio*>(address);}
};
// No IPC, locks, allocation, or reference-counted destruction in an audio callback.
class MappingSlot {
    std::atomic<Mapping*> current{nullptr};std::atomic<uint32_t> readers{0};
    std::vector<std::unique_ptr<Mapping>> retired;std::unique_ptr<Mapping> owned;
public:
    class Read {MappingSlot& slot;public:SharedAudio* audio;
        explicit Read(MappingSlot& s):slot(s){s.readers.fetch_add(1);auto* m=s.current.load();audio=m?m->get():nullptr;}
        ~Read(){slot.readers.fetch_sub(1);}Read(const Read&)=delete;Read& operator=(const Read&)=delete;
    };
    bool replace(std::unique_ptr<Mapping> next); // single control thread only
    void collect();
};
// Non-real-time request helper, with bounded waits and validated reply types.
class Client {
    xpc_connection_t connection=nullptr;dispatch_queue_t queue=nullptr;
public:
    Client()=default;~Client();Client(const Client&)=delete;Client& operator=(const Client&)=delete;
    void connect(const char* name=serviceName);
    xpc_object_t request(xpc_object_t message,unsigned timeoutMs=1500);
    xpc_object_t call(const char* operation,unsigned timeoutMs=1500);
};
xpc_object_t message(const char* operation);
uint32_t status(xpc_object_t reply);
double ticksPerSecond();
}
